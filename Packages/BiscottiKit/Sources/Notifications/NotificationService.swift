import Foundation
import os
import UserNotifications

/// Manages notification lifecycle: authorization, presentation, countdown cancellation,
/// and the typed action stream consumed by AppCore.
///
/// This module **presents and reports intent only**; `AppCore` performs the action.
@MainActor
public final class NotificationService {
    private let provider: any NotificationCenterProviding
    private let logger = Logger(
        subsystem: "net.scosman.biscotti",
        category: "Notifications"
    )

    /// Cached authorization status. Updated after `requestAuthorization()` and
    /// before each `present` call.
    private var cachedAuthStatus: UNAuthorizationStatus?

    /// The stream continuation for `actions()`. Created lazily on first call.
    private var continuation: AsyncStream<NotificationAction>.Continuation?
    private var stream: AsyncStream<NotificationAction>?

    /// Creates the service, registers categories, and prepares the action stream.
    ///
    /// - Parameter provider: The notification center seam (defaults to the live
    ///   `UNUserNotificationCenter` wrapper).
    public init(
        provider: any NotificationCenterProviding = LiveNotificationCenter()
    ) {
        self.provider = provider
        registerCategories()
    }

    // MARK: - Authorization

    /// Requests notification authorization (alert + sound).
    /// Returns `true` if granted. Safe to call multiple times.
    public func requestAuthorization() async -> Bool {
        logger.info("requestAuthorization: entry, options=[.alert, .sound]")
        do {
            let granted = try await provider.requestAuthorization()
            cachedAuthStatus = granted ? .authorized : .denied
            logger.info(
                "requestAuthorization: result granted=\(granted)"
            )
            return granted
        } catch {
            logger.error(
                "requestAuthorization: threw error: \(error)"
            )
            cachedAuthStatus = .denied
            return false
        }
    }

    /// Queries the live notification authorization status from the system.
    /// Returns `true` if currently authorized (any flavor), `false` otherwise.
    /// Also refreshes the internal cache.
    public func isCurrentlyAuthorized() async -> Bool {
        let status = await provider.authorizationStatus()
        cachedAuthStatus = status
        switch status {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied, .notDetermined:
            return false
        @unknown default:
            return false
        }
    }

    /// Whether the user has explicitly denied notifications (vs. never asked).
    public func isDenied() async -> Bool {
        let status = await provider.authorizationStatus()
        cachedAuthStatus = status
        return status == .denied
    }

    // MARK: - Presentation

    /// Posts a notification for the given kind.
    /// No-op if authorization was denied.
    public func present(_ kind: NotificationKind) async {
        guard await isAuthorized() else {
            logger.warning("Notification auth denied; skipping present")
            return
        }

        let request = makeRequest(for: kind)
        do {
            try await provider.add(request)
            logger.info(
                "present: added \(request.content.categoryIdentifier) request \(request.identifier)"
            )
        } catch {
            logger.error("Failed to add notification: \(error)")
        }
    }

    /// Removes the stop-countdown notification.
    /// Always executes regardless of auth status (cleanup is always valid).
    public func cancelCountdown(meetingID: UUID) async {
        let identifier = countdownRequestIdentifier(meetingID: meetingID)
        provider.removePendingRequests(withIdentifiers: [identifier])
        provider.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    // MARK: - Action stream

    /// An unbounded `AsyncStream` of typed actions from user interactions with
    /// notifications. Single-consumer (AppCore). The stream is fed by the app-target
    /// delegate calling `handleResponse(_:)`.
    public func actions() -> AsyncStream<NotificationAction> {
        if let stream {
            return stream
        }

        let (newStream, newContinuation) = AsyncStream
            .makeStream(of: NotificationAction.self)
        continuation = newContinuation
        stream = newStream
        return newStream
    }

    // MARK: - Delegate bridge

    /// Types a raw `UNNotificationResponse` into a `NotificationAction` and pushes
    /// it onto the `actions()` stream. Called by the app-target's
    /// `UNUserNotificationCenterDelegate`.
    ///
    /// Returns `true` if the response was recognized and enqueued; `false` for
    /// dismiss/unknown.
    @discardableResult
    public func handleResponse(_ response: UNNotificationResponse) -> Bool {
        let content = response.notification.request.content
        return handleResponseValues(
            categoryID: content.categoryIdentifier,
            actionID: response.actionIdentifier,
            userInfo: content.userInfo
        )
    }

    /// Testable entry point: types raw values into a `NotificationAction` and
    /// pushes onto the stream. Public so tests can drive it without constructing
    /// a `UNNotificationResponse`.
    @discardableResult
    public func handleResponseValues(
        categoryID: String,
        actionID: String,
        userInfo: [AnyHashable: Any]
    ) -> Bool {
        guard let action = mapResponse(
            categoryID: categoryID,
            actionID: actionID,
            userInfo: userInfo
        ) else {
            return false
        }

        // Ensure the stream exists so the continuation is non-nil.
        _ = actions()
        continuation?.yield(action)
        return true
    }

    /// Called by the app-target delegate for `willPresent`. Returns the
    /// presentation options to use when a notification arrives while the app
    /// is in the foreground.
    public func foregroundPresentationOptions(
        for _: UNNotification
    ) -> UNNotificationPresentationOptions {
        // Always show banner + sound in the foreground.
        // The stop-countdown notification is the only surface for the "Keep
        // recording" action — it must be visible even when the app is frontmost.
        [.banner, .sound]
    }

    // MARK: - Private

    private func registerCategories() {
        let openAndRecord = UNNotificationAction(
            identifier: ActionID.openAndRecord,
            title: "Open & Record",
            options: [.foreground]
        )
        let join = UNNotificationAction(
            identifier: ActionID.join,
            title: "Join",
            options: [.foreground]
        )
        let record = UNNotificationAction(
            identifier: ActionID.record,
            title: "Record",
            options: []
        )
        let keepRecording = UNNotificationAction(
            identifier: ActionID.keepRecording,
            title: "Keep Recording",
            options: [.foreground]
        )

        let meetingStart = UNNotificationCategory(
            identifier: CategoryID.meetingStarting,
            actions: [openAndRecord],
            intentIdentifiers: []
        )
        let meetingStartWithJoin = UNNotificationCategory(
            identifier: CategoryID.meetingStartingWithJoin,
            actions: [openAndRecord, join],
            intentIdentifiers: []
        )
        let adHoc = UNNotificationCategory(
            identifier: CategoryID.adHocDetected,
            actions: [record],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        let countdown = UNNotificationCategory(
            identifier: CategoryID.stopCountdown,
            actions: [keepRecording],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )

        provider.setCategories([
            meetingStart,
            meetingStartWithJoin,
            adHoc,
            countdown
        ])
    }

    /// Checks (and caches) whether notification authorization is currently granted.
    private func isAuthorized() async -> Bool {
        if let cached = cachedAuthStatus {
            return cached == .authorized
        }
        let status = await provider.authorizationStatus()
        cachedAuthStatus = status
        return status == .authorized
    }
}

// MARK: - Request building (nonisolated to avoid sending issues)

/// Builds a `UNNotificationRequest` for the given kind.
///
/// Free function (not `@MainActor`) so the returned request can cross isolation
/// boundaries without a "sending risks data race" diagnostic in Swift 6.
private func makeRequest(for kind: NotificationKind) -> UNNotificationRequest {
    let content = UNMutableNotificationContent()
    let identifier = requestIdentifier(for: kind)

    switch kind {
    case let .meetingStarting(eventKey, title, joinURL):
        fillMeetingStartContent(
            content, eventKey: eventKey, title: title, joinURL: joinURL
        )

    case let .adHocDetected(bundleID, appName):
        content.title = "Meeting detected in \(appName)"
        content.body = "Tap Record to start capturing."
        content.sound = .default
        content.categoryIdentifier = CategoryID.adHocDetected
        content.userInfo = [
            UserInfoKey.kind: KindValue.adHoc,
            UserInfoKey.bundleID: bundleID
        ]

    case let .stopCountdown(meetingID, secondsRemaining):
        fillCountdownContent(
            content, meetingID: meetingID, secondsRemaining: secondsRemaining
        )
    }

    return UNNotificationRequest(
        identifier: identifier, content: content, trigger: nil
    )
}

private func fillMeetingStartContent(
    _ content: UNMutableNotificationContent,
    eventKey: String,
    title: String,
    joinURL: URL?
) {
    content.title = title
    content.body = ""
    content.sound = .default
    content.categoryIdentifier = joinURL != nil
        ? CategoryID.meetingStartingWithJoin
        : CategoryID.meetingStarting

    var info: [String: String] = [
        UserInfoKey.kind: KindValue.meetingStarting,
        UserInfoKey.eventKey: eventKey
    ]
    if let joinURL {
        info[UserInfoKey.joinURL] = joinURL.absoluteString
    }
    content.userInfo = info
}

private func fillCountdownContent(
    _ content: UNMutableNotificationContent,
    meetingID: UUID,
    secondsRemaining: Int
) {
    content.title = "Recording will stop in \(secondsRemaining)s"
    content.body = "Tap to keep recording"
    content.sound = .default
    content.categoryIdentifier = CategoryID.stopCountdown
    content.userInfo = [
        UserInfoKey.kind: KindValue.countdown,
        UserInfoKey.meetingID: meetingID.uuidString
    ]
}
