import AppCore
import AppShellUI
import MenuBarUI
import Notifications
import os
import ServiceManagement
import SettingsUI
import SwiftUI
import UserNotifications

/// The Biscotti app entry point.
///
/// Builds a fully-wired `AppCore` (DataStore, Permissions, Recording,
/// TranscriptionService, Calendar, MeetingDetector, NotificationService)
/// and presents the `AppShellView` in a single-instance `Window` plus a
/// `MenuBarExtra` for background operation.
///
/// **Ownership model:** `AppCore` lives in `AppDelegate` (process-lifetime).
/// `BiscottiApp.body` reads the already-built core so it survives
/// window close/reopen without losing state.
///
/// **Observability:** `AppDelegate` is an `NSObject` subclass and cannot
/// itself be `@Observable`. The mutable startup state (`shellViewModel`,
/// `menuBarViewModel`, `launchError`) lives in `LaunchState`, an
/// `@Observable` class owned by the delegate.
///
/// **Important:** Scene-level `@ViewBuilder` closures (the trailing
/// closures of `Window` and `MenuBarExtra`) do NOT reliably
/// establish SwiftUI Observation tracking the way a `View.body` does.
/// Reads of `@Observable` properties inside those closures may never
/// trigger a re-render when the property changes. To work around this,
/// dedicated `View` structs (`WindowRootView`, `MenuBarRootContent`,
/// `MenuBarRootLabel`) accept `LaunchState` as a stored property and
/// read it inside their `body` — where Observation tracking IS
/// reliable. This ensures the nil-to-set transition of
/// `shellViewModel`/`menuBarViewModel` always invalidates the UI.
///
/// - TODO: License/attribution screen for argmax-oss-swift and model
///   licenses must be added before ship (Project 9).
@main
struct BiscottiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self)
    private var appDelegate

    var body: some Scene {
        // Single-instance Window (not WindowGroup) so `openWindow(id: "main")`
        // is idempotent — it reopens the one window, never spawns duplicates.
        // This is the right primitive for a single-main-window menu-bar app.
        Window("Biscotti", id: "main") {
            WindowRootView(launchState: appDelegate.launchState)
                .frame(minWidth: 640, minHeight: 400)
                .onReceive(NotificationCenter.default.publisher(
                    for: NSWindow.willCloseNotification
                )) { notification in
                    // Filter to real content windows; ignore sheets, panels,
                    // alerts, and file dialogs that also post this notification.
                    guard let window = notification.object as? NSWindow,
                          window.level == .normal
                    else { return }
                    // Schedule the policy switch for the next run loop so
                    // SwiftUI has finished tearing down the window.
                    Task { @MainActor in
                        appDelegate.handleWindowClosed()
                    }
                }
        }

        // Standard macOS Settings window (Biscotti > Settings..., Cmd+,).
        // Declaring a Settings scene adds the menu item automatically.
        Settings {
            SettingsRootView(launchState: appDelegate.launchState)
        }

        // Menu bar extra (native menu style)
        MenuBarExtra {
            MenuBarRootContent(launchState: appDelegate.launchState)
        } label: {
            MenuBarRootLabel(launchState: appDelegate.launchState)
        }
        .menuBarExtraStyle(.menu)
    }
}

// MARK: - Root View wrappers (reliable Observation tracking)

/// Root content for the `Window(id: "main")` scene. Reads `LaunchState`
/// inside `body` so the nil-to-set transition of `shellViewModel`
/// reliably triggers a SwiftUI re-render (Scene closures do not).
///
/// Also captures `@Environment(\.openWindow)` and injects it into
/// `LaunchState.sceneOpener` on appear. Because this view is shown at
/// launch (before any user interaction), the closure is available to
/// `AppDelegate.showMainWindow()` for dock-click and notification paths.
private struct WindowRootView: View {
    let launchState: LaunchState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if let shellVM = launchState.shellViewModel {
                AppShellView(viewModel: shellVM)
            } else if let err = launchState.launchError {
                errorView(message: err)
            } else {
                ProgressView("Starting Biscotti\u{2026}")
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity
                    )
            }
        }
        .onAppear {
            let captured = openWindow
            launchState.sceneOpener = {
                captured(id: "main")
            }
        }
        .background(WindowTitleHider())
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

/// Root content for the `Settings` scene. Reads `LaunchState` inside
/// `body` for reliable Observation tracking (Scene closures do not),
/// and hosts the package-provided `SettingsView`.
private struct SettingsRootView: View {
    let launchState: LaunchState

    var body: some View {
        Group {
            if let settingsVM = launchState.settingsViewModel {
                SettingsView(viewModel: settingsVM)
            } else {
                ProgressView("Loading\u{2026}")
                    .frame(width: 480, height: 300)
            }
        }
    }
}

/// Root content for the `MenuBarExtra` menu body. Reads `LaunchState`
/// inside `body` so the nil-to-set transition of `menuBarViewModel`
/// reliably triggers a SwiftUI re-render.
private struct MenuBarRootContent: View {
    let launchState: LaunchState

    var body: some View {
        if let menuBarVM = launchState.menuBarViewModel {
            MenuBarContentView(viewModel: menuBarVM)
        } else {
            Text("Starting\u{2026}")
        }
    }
}

/// Root label for the `MenuBarExtra` icon. Reads `LaunchState` inside
/// `body` so the nil-to-set transition of `menuBarViewModel` reliably
/// triggers a SwiftUI re-render.
private struct MenuBarRootLabel: View {
    let launchState: LaunchState

    var body: some View {
        if let menuBarVM = launchState.menuBarViewModel {
            MenuBarLabelView(viewModel: menuBarVM)
        } else {
            Image(systemName: "circle.dotted.circle")
        }
    }
}

// MARK: - Observable launch state

/// Holds the mutable state that the `BiscottiApp.body` reads to decide
/// what to show (spinner / error / app shell / menu bar). Because this
/// class is `@Observable`, mutations trigger SwiftUI re-renders
/// regardless of when `buildCore()` runs relative to the first body
/// evaluation.
@MainActor @Observable
final class LaunchState: @unchecked Sendable {
    var shellViewModel: AppShellViewModel?
    var menuBarViewModel: MenuBarViewModel?
    var settingsViewModel: SettingsViewModel?
    var launchError: String?

    /// Closure that calls `openWindow(id: "main")`. Captured from
    /// `WindowRootView`'s `@Environment(\.openWindow)` on appear and
    /// shared with `AppDelegate.showMainWindow()` so it can create the
    /// SwiftUI `Window` scene from AppKit code paths (dock click,
    /// notification actions). Set once on first `.onAppear`; nil until
    /// then (harmless: `showMainWindow` falls back to AppKit activate).
    @ObservationIgnored var sceneOpener: (@MainActor () -> Void)?

    /// Nonisolated init so `AppDelegate` (an `NSObject` subclass whose
    /// stored-property initializers run in a nonisolated context) can
    /// create the instance inline. All three properties start as `nil`;
    /// subsequent reads/writes happen on the MainActor.
    nonisolated init() {}
}

// MARK: - AppDelegate

/// Handles lifecycle events that require AppKit hooks:
/// - Owns the single long-lived `AppCore` instance (process lifetime).
/// - Owns `LaunchState` (the observable bridge to SwiftUI).
/// - Don't quit on last window close (keeps menu bar alive).
/// - Quit-while-recording: stop and save before terminating.
/// - `UNUserNotificationCenterDelegate`: forward notification
///   responses into `NotificationService`.
/// - Dock icon / activation-policy switching:
///   `.regular` when a window is open, `.accessory` when no windows.
/// - Window show/activate for menu-bar Open, dock click, and
///   notification actions.
final class AppDelegate: NSObject, NSApplicationDelegate,
    @preconcurrency UNUserNotificationCenterDelegate
{
    // MARK: - Core (process-lifetime, single instance)

    var core: AppCore?
    var notificationService: NotificationService?

    /// Observable state read by `BiscottiApp.body`. Mutations here
    /// trigger SwiftUI re-renders (fixes the startup-hang race).
    let launchState = LaunchState()

    private let logger = Logger(
        subsystem: "net.scosman.biscotti",
        category: "startup"
    )

    func applicationDidFinishLaunching(_: Notification) {
        logger.info("applicationDidFinishLaunching: enter")

        // Register as the notification center delegate for action handling.
        UNUserNotificationCenter.current().delegate = self

        // Build the core once, at launch. It lives for the process lifetime.
        // applicationDidFinishLaunching always runs on the main thread;
        // assumeIsolated lets us call @MainActor code synchronously.
        MainActor.assumeIsolated {
            self.buildCore()
        }
    }

    // MARK: - Window lifecycle

    func applicationShouldTerminateAfterLastWindowClosed(
        _: NSApplication
    ) -> Bool {
        false // Keep running in the menu bar.
    }

    /// Called when the user clicks the Dock icon while the app is running
    /// (and optionally when no window is open).
    func applicationShouldHandleReopen(
        _: NSApplication, hasVisibleWindows: Bool
    ) -> Bool {
        if !hasVisibleWindows {
            // applicationShouldHandleReopen runs on the main thread;
            // use assumeIsolated to call @MainActor code synchronously.
            MainActor.assumeIsolated {
                self.showMainWindow()
            }
        }
        return true
    }

    /// Called after a window closes. Switches to accessory mode
    /// (hides Dock icon) when no windows remain.
    @MainActor
    func handleWindowClosed() {
        let hasVisibleWindows = NSApp.windows.contains { window in
            window.isVisible && window.canBecomeMain
        }
        if !hasVisibleWindows {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// Shows the main window and switches to regular app mode
    /// (Dock icon visible). Called from menu bar "Open Biscotti",
    /// Dock icon click, and notification actions.
    ///
    /// Uses `launchState.sceneOpener` (captured from SwiftUI's
    /// `@Environment(\.openWindow)`) to request window creation via
    /// `openWindow(id: "main")`. This is necessary because AppKit's
    /// `activate()` alone cannot instantiate a SwiftUI `Window` scene
    /// from a cold (no-window) state. The `Window(id: "main")` scene
    /// is single-instance, so `openWindow` is idempotent — it reopens
    /// the existing window or creates one, never duplicates.
    @MainActor
    func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        // Request the SwiftUI Window scene to open/show.
        // This is idempotent: Window(id:) is single-instance.
        launchState.sceneOpener?()
        // Activate the app (brings to front).
        NSApp.activate()
        // If a main-capable window exists, bring it forward.
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - Quit-while-recording

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

    // MARK: - Build core (once, at launch)

    @MainActor
    private func buildCore() {
        logger.info("buildCore: enter")
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
            logger.info("buildCore: app-support dir resolved")

            logger.info("buildCore: AppCore.live starting")
            let appCore = try AppCore.live(
                storageRoot: storageRoot,
                transcriberServiceName:
                "net.scosman.biscotti.BiscottiTranscriber"
            )
            logger.info("buildCore: AppCore.live complete")

            core = appCore
            notificationService = appCore.notifications

            launchState.shellViewModel = AppShellViewModel(core: appCore)
            launchState.settingsViewModel = SettingsViewModel(core: appCore)
            launchState.menuBarViewModel = MenuBarViewModel(
                core: appCore,
                windowOpener: { [weak self] in
                    self?.showMainWindow()
                }
            )
            let hasShellVM = launchState.shellViewModel != nil
            let hasMenuBarVM = launchState.menuBarViewModel != nil
            logger.info(
                "buildCore: shellViewModel=\(hasShellVM), menuBarViewModel=\(hasMenuBarVM)"
            )

            // Register launch-at-login (default ON)
            registerLaunchAtLogin()
            logger.info("buildCore: registerLaunchAtLogin done")
        } catch {
            logger.error("buildCore: FAILED — \(error)")
            launchState.launchError = error.localizedDescription
        }
        logger.info("buildCore: done")
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
            showMainWindow()
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

// MARK: - Window title hider

/// An `NSViewRepresentable` that hides the hosting window's title text
/// while preserving the toolbar, traffic lights, and draggable title bar.
/// Placed as a `.background` on `WindowRootView` so it fires once the
/// view is installed in a window. Verified on device in Phase 4.
private struct WindowTitleHider: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSView {
        let view = NSView()
        // Defer to the next run-loop tick so the view is attached to a window.
        DispatchQueue.main.async {
            view.window?.titleVisibility = .hidden
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context _: Context) {
        // Re-apply in case the window was recreated (e.g. reopen from Dock).
        nsView.window?.titleVisibility = .hidden
    }
}
