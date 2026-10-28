import AppKit
import Foundation

/// Injectable environment for all OS interactions the send-to feature needs.
///
/// Every closure wraps one AppKit/Foundation call. Tests swap in fakes;
/// the `.live` instance wires to real `NSWorkspace` and `FileManager`.
public struct SendEnvironment: Sendable {
    /// `NSWorkspace.urlForApplication(toOpen:)` for a scheme URL.
    public var appURLForScheme: @Sendable @MainActor (String) -> URL?

    /// `NSWorkspace.urlForApplication(withBundleIdentifier:)`.
    public var appURLForBundleID: @Sendable @MainActor (String) -> URL?

    /// `NSWorkspace.open(_:)` for a URL. Returns true on success.
    public var openURL: @Sendable @MainActor (URL) -> Bool

    /// Opens a file with a specific application (Notes hand-off).
    public var openFile: @Sendable @MainActor (URL, URL) async throws -> Void

    /// `NSWorkspace.openApplication(at:configuration:)` with `activates = true`.
    public var openApp: @Sendable @MainActor (URL) -> Void

    /// Copies a string to the general pasteboard.
    public var writePasteboard: @Sendable @MainActor (String) -> Void

    /// The base temporary directory for file hand-off.
    public var tempRoot: @Sendable () -> URL

    /// The current date.
    public var now: @Sendable () -> Date

    /// The current time zone.
    public var timeZone: @Sendable () -> TimeZone

    public init(
        appURLForScheme: @escaping @Sendable @MainActor (String) -> URL?,
        appURLForBundleID: @escaping @Sendable @MainActor (String) -> URL?,
        openURL: @escaping @Sendable @MainActor (URL) -> Bool,
        openFile: @escaping @Sendable @MainActor (URL, URL) async throws -> Void,
        openApp: @escaping @Sendable @MainActor (URL) -> Void,
        writePasteboard: @escaping @Sendable @MainActor (String) -> Void,
        tempRoot: @escaping @Sendable () -> URL,
        now: @escaping @Sendable () -> Date,
        timeZone: @escaping @Sendable () -> TimeZone
    ) {
        self.appURLForScheme = appURLForScheme
        self.appURLForBundleID = appURLForBundleID
        self.openURL = openURL
        self.openFile = openFile
        self.openApp = openApp
        self.writePasteboard = writePasteboard
        self.tempRoot = tempRoot
        self.now = now
        self.timeZone = timeZone
    }

    /// The production environment wired to real NSWorkspace and FileManager.
    public static let live = SendEnvironment(
        appURLForScheme: { scheme in
            guard let schemeURL = URL(string: "\(scheme)://") else { return nil }
            return NSWorkspace.shared.urlForApplication(toOpen: schemeURL)
        },
        appURLForBundleID: { bundleID in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        },
        openURL: { url in
            NSWorkspace.shared.open(url)
        },
        openFile: { fileURL, appURL in
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            try await NSWorkspace.shared.open(
                [fileURL], withApplicationAt: appURL, configuration: config
            )
        },
        openApp: { appURL in
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(
                at: appURL, configuration: config
            )
        },
        writePasteboard: { text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        },
        tempRoot: {
            FileManager.default.temporaryDirectory
        },
        now: { Date() },
        timeZone: { .current }
    )
}
