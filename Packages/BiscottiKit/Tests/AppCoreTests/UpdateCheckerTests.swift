import Foundation
import Testing
@testable import AppCore

@Suite("UpdateChecker")
@MainActor
struct UpdateCheckerTests {
    // MARK: - Helpers

    private func makeRelease(
        tag: String,
        url: String = "https://github.com/scosman/Biscotti/releases/tag/v1.0.0"
    ) throws -> GitHubRelease {
        let parsedURL = try #require(URL(string: url))
        return GitHubRelease(
            tagName: tag,
            htmlURL: parsedURL
        )
    }

    private func makeChecker(
        currentVersion: String? = "0.2.0",
        releaseTag: String = "v0.2.0",
        releaseURL: String = "https://github.com/scosman/Biscotti/releases/tag/v0.2.0"
    ) throws -> UpdateChecker {
        let release = try makeRelease(tag: releaseTag, url: releaseURL)
        return UpdateChecker(
            currentVersion: { currentVersion },
            fetchRelease: { release }
        )
    }

    // MARK: - Initial state

    @Test("initial status is idle")
    func initialStatusIdle() throws {
        let checker = try makeChecker()
        #expect(checker.status == .idle)
        #expect(checker.isUpdateAvailable == false)
    }

    // MARK: - Up to date

    @Test("reports up to date when versions match")
    func upToDateWhenEqual() async throws {
        let checker = try makeChecker(
            currentVersion: "0.2.0",
            releaseTag: "v0.2.0"
        )
        await checker.check()
        #expect(checker.status == .upToDate("v0.2.0"))
        #expect(checker.isUpdateAvailable == false)
    }

    @Test("reports up to date when current is newer")
    func upToDateWhenNewer() async throws {
        let checker = try makeChecker(
            currentVersion: "1.0.0",
            releaseTag: "v0.2.0"
        )
        await checker.check()
        #expect(checker.status == .upToDate("v1.0.0"))
    }

    // MARK: - Update available

    @Test("reports update available when release is newer")
    func updateAvailable() async throws {
        let releaseURL = "https://github.com/scosman/Biscotti/releases/tag/v1.0.0"
        let checker = try makeChecker(
            currentVersion: "0.2.0",
            releaseTag: "v1.0.0",
            releaseURL: releaseURL
        )
        await checker.check()
        let expectedURL = try #require(URL(string: releaseURL))
        #expect(
            checker.status == .updateAvailable(
                version: "v1.0.0",
                releaseURL: expectedURL
            )
        )
        #expect(checker.isUpdateAvailable == true)
        #expect(checker.releaseURL == expectedURL)
    }

    @Test("update available with pre-release suffix stripped")
    func updateAvailablePreRelease() async throws {
        let checker = try makeChecker(
            currentVersion: "0.2.0",
            releaseTag: "v1.0.0-beta"
        )
        await checker.check()
        #expect(checker.isUpdateAvailable == true)
    }

    // MARK: - Failure cases

    @Test("reports failed when fetch throws")
    func failedOnFetchError() async {
        let checker = UpdateChecker(
            currentVersion: { "0.2.0" },
            fetchRelease: { throw NSError(domain: "test", code: -1) }
        )
        await checker.check()
        #expect(checker.status == .failed)
        #expect(checker.isUpdateAvailable == false)
    }

    @Test("reports failed when current version is nil")
    func failedOnNilCurrentVersion() async throws {
        let checker = try makeChecker(
            currentVersion: nil,
            releaseTag: "v1.0.0"
        )
        await checker.check()
        #expect(checker.status == .failed)
    }

    @Test("reports failed when current version is unparseable")
    func failedOnUnparseableCurrentVersion() async throws {
        let checker = try makeChecker(
            currentVersion: "not-a-version",
            releaseTag: "v1.0.0"
        )
        await checker.check()
        #expect(checker.status == .failed)
    }

    @Test("reports failed when release tag is unparseable")
    func failedOnUnparseableReleaseTag() async throws {
        let checker = try makeChecker(
            currentVersion: "0.2.0",
            releaseTag: "latest"
        )
        await checker.check()
        #expect(checker.status == .failed)
    }

    // MARK: - Derived state

    @Test("releaseURL is nil when no update available")
    func releaseURLNilWhenUpToDate() async throws {
        let checker = try makeChecker(
            currentVersion: "1.0.0",
            releaseTag: "v1.0.0"
        )
        await checker.check()
        #expect(checker.releaseURL == nil)
    }

    @Test("releaseURL returns URL when update available")
    func releaseURLWhenUpdateAvailable() async throws {
        let expectedURL = "https://github.com/scosman/Biscotti/releases/tag/v2.0.0"
        let checker = try makeChecker(
            currentVersion: "0.2.0",
            releaseTag: "v2.0.0",
            releaseURL: expectedURL
        )
        await checker.check()
        let parsedURL = try #require(URL(string: expectedURL))
        #expect(checker.releaseURL == parsedURL)
    }

    // MARK: - Checking state transitions

    @Test("status transitions through checking to terminal state")
    func statusTransitions() async throws {
        let checker = try makeChecker(
            currentVersion: "0.2.0",
            releaseTag: "v0.2.0"
        )

        #expect(checker.status == .idle)
        await checker.check()
        // After check completes, status should be a terminal state
        #expect(checker.status == .upToDate("v0.2.0"))
    }

    // MARK: - Numeric vs lexicographic

    @Test("v10.1.2 > v2.0 handled correctly")
    func numericComparisonInChecker() async throws {
        let checker = try makeChecker(
            currentVersion: "2.0",
            releaseTag: "v10.1.2"
        )
        await checker.check()
        #expect(checker.isUpdateAvailable == true)
    }

    // MARK: - Privacy: User-Agent header

    @Test("User-Agent is non-empty and contains no version digits")
    func userAgentPrivacy() throws {
        let request = try UpdateChecker.makeGitHubRequest()
        let userAgent = try #require(
            request.value(forHTTPHeaderField: "User-Agent")
        )
        #expect(!userAgent.isEmpty, "User-Agent must not be empty (GitHub rejects it)")
        #expect(
            userAgent.range(of: #"\d"#, options: .regularExpression) == nil,
            "User-Agent must not contain digits (would leak the app version)"
        )
    }
}
