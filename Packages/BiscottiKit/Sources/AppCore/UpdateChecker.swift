import Foundation

/// The current state of the update check.
public enum UpdateStatus: Sendable, Equatable {
    /// No check has been performed yet.
    case idle

    /// A check is in progress.
    case checking

    /// The running version matches or exceeds the latest release.
    case upToDate(String)

    /// A newer release is available.
    case updateAvailable(version: String, releaseURL: URL)

    /// The check failed (offline, rate-limited, bad response).
    case failed
}

/// Checks for app updates by comparing the running version against
/// the latest GitHub release.
///
/// **Privacy:** contacts only `api.github.com` with a single
/// unauthenticated GET. Sends zero identifying information — no
/// analytics headers, no query parameters, no UUIDs, no
/// app-version header. Nothing about the user leaves the machine.
@MainActor @Observable
public final class UpdateChecker {
    // MARK: - Published state

    /// Current check result. The UI binds to this.
    public private(set) var status: UpdateStatus = .idle

    // MARK: - Dependencies (injected for testability)

    /// Returns the running app's version string (e.g. `"0.2.0"`).
    private let currentVersion: @Sendable () -> String?

    /// Fetches the latest release metadata from GitHub.
    /// Returns the tag name and the HTML URL of the release page.
    private let fetchRelease: @Sendable () async throws -> GitHubRelease

    /// How long to wait between automatic checks.
    private let checkInterval: Duration

    // nonisolated(unsafe): only mutated from @MainActor methods;
    // read in deinit when no other references exist.
    private nonisolated(unsafe) var periodicTask: Task<Void, Never>?

    // MARK: - Init

    /// - Parameters:
    ///   - currentVersion: Closure returning the app's marketing version.
    ///     Defaults to `CFBundleShortVersionString` from the main bundle.
    ///   - fetchRelease: Closure that fetches the latest release info.
    ///     Defaults to the live GitHub API call.
    ///   - checkInterval: Time between periodic checks (default 12 hours).
    public init(
        currentVersion: (@Sendable () -> String?)? = nil,
        fetchRelease: (@Sendable () async throws -> GitHubRelease)? = nil,
        checkInterval: Duration = .seconds(12 * 60 * 60)
    ) {
        self.currentVersion = currentVersion ?? {
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        }
        self.fetchRelease = fetchRelease ?? Self.fetchFromGitHub
        self.checkInterval = checkInterval
    }

    // MARK: - Actions

    /// Performs a single update check. Updates `status` throughout.
    public func check() async {
        status = .checking

        do {
            let release = try await fetchRelease()

            guard let currentString = currentVersion(),
                  let current = SemanticVersion(currentString),
                  let latest = SemanticVersion(release.tagName)
            else {
                // Fail closed: unparseable version → don't claim update available
                status = .failed
                return
            }

            if latest > current {
                status = .updateAvailable(
                    version: latest.displayString,
                    releaseURL: release.htmlURL
                )
            } else {
                status = .upToDate(current.displayString)
            }
        } catch {
            status = .failed
        }
    }

    deinit {
        periodicTask?.cancel()
    }

    /// Starts periodic checking: once immediately, then every
    /// `checkInterval`. Timer-based (relative to call time), not
    /// wall-clock, to avoid synchronized bursts across installs.
    public func startPeriodicChecks() {
        periodicTask?.cancel()
        let interval = checkInterval
        periodicTask = Task { [weak self] in
            await self?.check()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return // cancelled
                }
                guard !Task.isCancelled else { return }
                await self?.check()
            }
        }
    }

    // MARK: - Derived state

    /// Whether an update is available (drives the sidebar dot).
    public var isUpdateAvailable: Bool {
        if case .updateAvailable = status { return true }
        return false
    }

    /// The release page URL when an update is available.
    public var releaseURL: URL? {
        if case let .updateAvailable(_, url) = status { return url }
        return nil
    }

    // MARK: - GitHub API

    /// Builds the URLRequest for the GitHub releases endpoint.
    /// Exposed as `package` so tests can verify headers without
    /// hitting the network.
    package static func makeGitHubRequest() throws -> URLRequest {
        guard let url = URL(
            string: "https://api.github.com/repos/scosman/Biscotti/releases/latest"
        ) else {
            throw UpdateCheckError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        // Accept header for the GitHub REST API
        request.setValue(
            "application/vnd.github+json",
            forHTTPHeaderField: "Accept"
        )
        // Override the default User-Agent (which leaks the app name
        // and marketing version). A static, non-versioned string
        // satisfies GitHub's "valid User-Agent" requirement without
        // sending any user-identifying data. Do not append a version
        // number — the privacy spec prohibits it.
        request.setValue("Biscotti", forHTTPHeaderField: "User-Agent")
        return request
    }

    private static func fetchFromGitHub() async throws -> GitHubRelease {
        let request = try makeGitHubRequest()

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200 ... 299).contains(httpResponse.statusCode)
        else {
            throw UpdateCheckError.httpError
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tagName = json["tag_name"] as? String,
              let htmlURLString = json["html_url"] as? String,
              let htmlURL = URL(string: htmlURLString)
        else {
            throw UpdateCheckError.invalidResponse
        }

        return GitHubRelease(tagName: tagName, htmlURL: htmlURL)
    }
}

// MARK: - Supporting types

/// Metadata from a GitHub release needed for the update check.
public struct GitHubRelease: Sendable {
    public let tagName: String
    public let htmlURL: URL

    public init(tagName: String, htmlURL: URL) {
        self.tagName = tagName
        self.htmlURL = htmlURL
    }
}

private enum UpdateCheckError: Error {
    case invalidURL
    case httpError
    case invalidResponse
}
