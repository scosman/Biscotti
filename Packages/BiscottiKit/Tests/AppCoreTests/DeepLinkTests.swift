import BiscottiTestSupport
import DataStore
import Foundation
import Testing
@testable import AppCore

// MARK: - Deep-link URL parsing tests

@Suite("AppCore -- deep link parsing")
struct DeepLinkParsingTests {
    @Test("valid biscotti://meeting/{id}?time=42.0 sets selection and pending jump")
    @MainActor
    func validDeepLinkSetsSelectionAndJump() async throws {
        let fix = try makeCoreFixture(testName: "DeepLinkTests")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(title: "Deep Link Meeting")

        let url = try #require(URL(string: "biscotti://meeting/\(meetingID.uuidString)?time=42.0"))
        await fix.core.handleDeepLink(url)

        #expect(fix.core.route == .meetings)
        #expect(fix.core.meetingsSelection == [meetingID])
        #expect(fix.core.pendingTranscriptJump != nil)
        #expect(fix.core.pendingTranscriptJump?.meetingID == meetingID)
        #expect(fix.core.pendingTranscriptJump?.time == 42.0)
    }

    @Test("integer time value is accepted")
    @MainActor
    func integerTimeAccepted() async throws {
        let fix = try makeCoreFixture(testName: "DeepLinkTests")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(title: "Integer Time")

        let url = try #require(URL(string: "biscotti://meeting/\(meetingID.uuidString)?time=90"))
        await fix.core.handleDeepLink(url)

        #expect(fix.core.pendingTranscriptJump?.meetingID == meetingID)
        #expect(fix.core.pendingTranscriptJump?.time == 90.0)
    }

    @Test("fractional time value is preserved")
    @MainActor
    func fractionalTimePreserved() async throws {
        let fix = try makeCoreFixture(testName: "DeepLinkTests")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(title: "Fractional Time")

        let url = try #require(URL(string: "biscotti://meeting/\(meetingID.uuidString)?time=102.7"))
        await fix.core.handleDeepLink(url)

        #expect(fix.core.pendingTranscriptJump?.time == 102.7)
    }

    @Test("missing time query parameter is a no-op")
    @MainActor
    func missingTimeIsNoOp() async throws {
        let fix = try makeCoreFixture(testName: "DeepLinkTests")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(title: "No Time")

        let url = try #require(URL(string: "biscotti://meeting/\(meetingID.uuidString)"))
        await fix.core.handleDeepLink(url)

        #expect(fix.core.pendingTranscriptJump == nil)
        // Route should still be .home (default), not changed
        #expect(fix.core.route == .home)
    }

    @Test("invalid UUID is a no-op")
    @MainActor
    func invalidUUIDIsNoOp() async throws {
        let fix = try makeCoreFixture(testName: "DeepLinkTests")
        defer { fix.cleanup() }

        let url = try #require(URL(string: "biscotti://meeting/not-a-uuid?time=42.0"))
        await fix.core.handleDeepLink(url)

        #expect(fix.core.pendingTranscriptJump == nil)
        #expect(fix.core.route == .home)
    }

    @Test("wrong scheme is a no-op")
    @MainActor
    func wrongSchemeIsNoOp() async throws {
        let fix = try makeCoreFixture(testName: "DeepLinkTests")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(title: "Wrong Scheme")

        let url = try #require(URL(string: "https://meeting/\(meetingID.uuidString)?time=42.0"))
        await fix.core.handleDeepLink(url)

        #expect(fix.core.pendingTranscriptJump == nil)
        #expect(fix.core.route == .home)
    }

    @Test("wrong host is a no-op")
    @MainActor
    func wrongHostIsNoOp() async throws {
        let fix = try makeCoreFixture(testName: "DeepLinkTests")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(title: "Wrong Host")

        // "seek" host (the in-SwiftUI transcript links) should not be handled
        let url = try #require(URL(string: "biscotti://seek?t=42.0&id=\(meetingID.uuidString)"))
        await fix.core.handleDeepLink(url)

        #expect(fix.core.pendingTranscriptJump == nil)
        #expect(fix.core.route == .home)
    }

    @Test("non-existent meeting ID is a no-op")
    @MainActor
    func nonExistentMeetingIsNoOp() async throws {
        let fix = try makeCoreFixture(testName: "DeepLinkTests")
        defer { fix.cleanup() }

        let bogusID = UUID()
        let url = try #require(URL(string: "biscotti://meeting/\(bogusID.uuidString)?time=42.0"))
        await fix.core.handleDeepLink(url)

        #expect(fix.core.pendingTranscriptJump == nil)
        #expect(fix.core.route == .home)
    }

    @Test("consumeTranscriptJump clears pending jump")
    @MainActor
    func consumeClearsPendingJump() async throws {
        let fix = try makeCoreFixture(testName: "DeepLinkTests")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(title: "Consume Test")

        let url = try #require(URL(string: "biscotti://meeting/\(meetingID.uuidString)?time=42.0"))
        await fix.core.handleDeepLink(url)
        #expect(fix.core.pendingTranscriptJump != nil)

        fix.core.consumeTranscriptJump()
        #expect(fix.core.pendingTranscriptJump == nil)
    }

    @Test("non-numeric time is a no-op")
    @MainActor
    func nonNumericTimeIsNoOp() async throws {
        let fix = try makeCoreFixture(testName: "DeepLinkTests")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(title: "Bad Time")

        let url = try #require(URL(string: "biscotti://meeting/\(meetingID.uuidString)?time=abc"))
        await fix.core.handleDeepLink(url)

        #expect(fix.core.pendingTranscriptJump == nil)
        #expect(fix.core.route == .home)
    }

    @Test("uppercase UUID is accepted")
    @MainActor
    func uppercaseUUIDAccepted() async throws {
        let fix = try makeCoreFixture(testName: "DeepLinkTests")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(title: "Uppercase UUID")

        let url = try #require(URL(string: "biscotti://meeting/\(meetingID.uuidString.uppercased())?time=10.0"))
        await fix.core.handleDeepLink(url)

        #expect(fix.core.pendingTranscriptJump?.meetingID == meetingID)
        #expect(fix.core.pendingTranscriptJump?.time == 10.0)
    }
}
