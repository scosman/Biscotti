import AppCore
import AppShellUI
import MenuBarUI
import Notifications
import ServiceManagement
import SwiftUI
import UserNotifications

/// The Biscotti app entry point.
///
/// Builds a fully-wired `AppCore` (DataStore, Permissions, Recording,
/// TranscriptionService, Calendar, MeetingDetector, NotificationService)
/// and presents the `AppShellView` in a `WindowGroup` plus a
/// `MenuBarExtra` for background operation.
///
/// - TODO: License/attribution screen for argmax-oss-swift and model
///   licenses must be added before ship (Project 9).
@main
struct BiscottiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self)
    private var appDelegate

    @State private var core: AppCore?
    @State private var shellViewModel: AppShellViewModel?
    @State private var menuBarViewModel: MenuBarViewModel?
    @State private var launchError: String?

    var body: some Scene {
        WindowGroup {
            Group {
                if let shellViewModel {
                    AppShellView(viewModel: shellViewModel)
                } else if let launchError {
                    errorView(message: launchError)
                } else {
                    ProgressView("Starting Biscotti\u{2026}")
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity
                        )
                }
            }
            .frame(minWidth: 640, minHeight: 400)
            .task { buildCore() }
        }

        // Menu bar extra (background operation)
        MenuBarExtra {
            if let menuBarViewModel {
                MenuBarContentView(viewModel: menuBarViewModel)
            } else {
                Text("Starting\u{2026}")
            }
        } label: {
            if let menuBarViewModel {
                MenuBarLabelView(viewModel: menuBarViewModel)
            } else {
                Image(systemName: "circle.dotted.circle")
            }
        }
        .menuBarExtraStyle(.window)
    }

    private func buildCore() {
        do {
            let appSupport = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let storageRoot = appSupport
                .appendingPathComponent("Biscotti")
            try FileManager.default.createDirectory(
                at: storageRoot,
                withIntermediateDirectories: true
            )

            let appCore = try AppCore.live(
                storageRoot: storageRoot,
                transcriberServiceName:
                "net.scosman.biscotti.BiscottiTranscriber"
            )
            core = appCore
            appDelegate.core = appCore
            appDelegate.notificationService = appCore.notifications
            shellViewModel = AppShellViewModel(core: appCore)
            menuBarViewModel = MenuBarViewModel(core: appCore)

            // Register launch-at-login (default ON)
            registerLaunchAtLogin()
        } catch {
            launchError = error.localizedDescription
        }
    }

    private func registerLaunchAtLogin() {
        let service = SMAppService.mainApp
        if service.status == .notRegistered {
            do {
                try service.register()
            } catch {
                // Non-fatal: user can enable from Settings later.
            }
        }
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.red)
            Text("Failed to start Biscotti")
                .font(.headline)
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - AppDelegate

/// Handles lifecycle events that require AppKit hooks:
/// - Don't quit on last window close (keeps menu bar alive).
/// - Quit-while-recording: stop and save before terminating.
/// - `UNUserNotificationCenterDelegate`: forward notification
///   responses into `NotificationService`.
final class AppDelegate: NSObject, NSApplicationDelegate,
    @preconcurrency UNUserNotificationCenterDelegate
{
    var core: AppCore?
    var notificationService: NotificationService?

    func applicationDidFinishLaunching(_: Notification) {
        // Register as the notification center delegate for action handling.
        UNUserNotificationCenter.current().delegate = self
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _: NSApplication
    ) -> Bool {
        false // Keep running in the menu bar.
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard let core else { return .terminateNow }

        // If recording, stop and save first.
        if core.recording.state.isRecording {
            Task { @MainActor in
                await core.stopRecording()
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }

        return .terminateNow
    }

    // MARK: - UNUserNotificationCenterDelegate

    @MainActor
    func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        // Extract Sendable data from the non-Sendable response before
        // any isolation boundary. All reads happen here, on the caller's
        // context, then we work with plain strings/dictionaries.
        let categoryID = response.notification.request.content
            .categoryIdentifier
        let actionID = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo

        // Forward the typed action to NotificationService's actions() stream.
        // NOTE: Join URL opening is handled HERE in the delegate (below),
        // not via the actions() stream. AppCore's consumer intentionally
        // `break`s on .join to stay AppKit-free. If this delegate is ever
        // refactored to stop opening URLs directly, update AppCore's
        // .join case to handle it instead.
        let recognized = notificationService?.handleResponseValues(
            categoryID: categoryID,
            actionID: actionID,
            userInfo: userInfo
        ) ?? false

        // If the action was not a recognized notification category, bail.
        if !recognized { return }
        if actionID == "biscotti.action.join",
           let urlString = userInfo["biscotti.joinURL"] as? String,
           let url = URL(string: urlString)
        {
            NSWorkspace.shared.open(url)
        }

        // Activate the app for foreground actions.
        if actionID == "biscotti.action.open-and-record"
            || actionID == "biscotti.action.record"
        {
            NSApplication.shared.activate(
                ignoringOtherApps: true
            )
        }
    }

    @MainActor
    func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        notificationService?.foregroundPresentationOptions(
            for: notification
        ) ?? [.banner, .sound]
    }
}
