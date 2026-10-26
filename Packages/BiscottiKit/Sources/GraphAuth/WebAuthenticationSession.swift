import AppKit
import AuthenticationServices
import os

/// Runs the browser part of an interactive sign-in. The seam tests replace
/// with a canned redirect.
@MainActor
public protocol WebAuthenticationSessionRunning: AnyObject {
    /// Opens `url` and returns the redirect to `callbackScheme`. Throws
    /// `.cancelled` when the user closes the window or `cancel()` is called.
    func authenticate(url: URL, callbackScheme: String) async throws(GraphAuthError) -> URL
    func cancel()
}

/// The production runner: `ASWebAuthenticationSession`, which uses the
/// system browser's cookies, so a user already signed in to Microsoft 365
/// in Safari (or covered by the Enterprise SSO plug-in) may not be asked for
/// a password. The custom-scheme callback is caught by the session itself;
/// the scheme does not need to be registered in `Info.plist`.
@MainActor
public final class SystemWebAuthenticationSession: NSObject, WebAuthenticationSessionRunning {
    private var session: ASWebAuthenticationSession?

    override public init() {
        super.init()
    }

    public func authenticate(url: URL, callbackScheme: String) async throws(GraphAuthError) -> URL {
        guard session == nil else {
            throw .presentation("A sign-in window is already open.")
        }
        let result: Result<URL, GraphAuthError> = await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            // `@Sendable` so the handler is not treated as main-actor
            // isolated: AuthenticationServices does not promise which
            // thread calls it.
            let session = ASWebAuthenticationSession(
                url: url,
                callback: .customScheme(callbackScheme)
            ) { @Sendable callbackURL, error in
                once.resume(with: Self.result(callbackURL: callbackURL, error: error))
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                once.resume(with: .failure(.presentation("The system refused to start the sign-in session.")))
            }
        }
        session = nil
        return try result.get()
    }

    public func cancel() {
        session?.cancel()
    }

    private nonisolated static func result(callbackURL: URL?, error: (any Error)?) -> Result<URL, GraphAuthError> {
        if let callbackURL {
            return .success(callbackURL)
        }
        if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
            return .failure(.cancelled)
        }
        return .failure(.presentation(error?.localizedDescription ?? "The sign-in window closed without a response."))
    }
}

extension SystemWebAuthenticationSession: ASWebAuthenticationPresentationContextProviding {
    /// The key window: Settings for the Connect button, the main window for
    /// the Home banner.
    public func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let app = NSApplication.shared
        return app.keyWindow ?? app.mainWindow ?? app.windows.first { $0.isVisible } ?? ASPresentationAnchor()
    }
}

/// Resumes a continuation at most once. The completion handler and a
/// failed `start()` could otherwise both resume it.
private final class ResumeOnce: Sendable {
    private let continuation: OSAllocatedUnfairLock<CheckedContinuation<Result<URL, GraphAuthError>, Never>?>

    init(_ continuation: CheckedContinuation<Result<URL, GraphAuthError>, Never>) {
        self.continuation = OSAllocatedUnfairLock(initialState: continuation)
    }

    func resume(with result: Result<URL, GraphAuthError>) {
        let pending = continuation.withLock { value in
            defer { value = nil }
            return value
        }
        pending?.resume(returning: result)
    }
}
