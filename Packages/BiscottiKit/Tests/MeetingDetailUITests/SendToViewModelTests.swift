import BiscottiTestSupport
import DataStore
import Foundation
import ImportExport
import Testing
@testable import AppCore
@testable import MeetingDetailUI

/// Fixed date for the send-to tests, at file scope so Sendable closures can capture it.
private let sendToFixedDate = Date(timeIntervalSinceReferenceDate: 810_000_000)

// Fixed time zone for the send-to tests.
// swiftlint:disable:next force_unwrapping
private let sendToFixedTimeZone = TimeZone(identifier: "America/New_York")!

@Suite("MeetingDetailViewModel -- Send to app")
@MainActor
struct SendToViewModelTests {
    // MARK: - Helpers

    /// Mutable reference box for tracking fake environment calls.
    final class FakeBox: @unchecked Sendable {
        var openedURLs: [URL] = []
        var openedFiles: [(file: URL, app: URL)] = []
        var openedApps: [URL] = []
        var pasteboardText: String?
        var openURLResult: Bool = true
    }

    /// Creates a fixture where all three destinations are "installed".
    private static func makeFixture(
        testName: String,
        box: FakeBox
    ) throws -> CoreFixture {
        let env = SendEnvironment(
            appURLForScheme: { scheme in
                switch scheme {
                case "obsidian":
                    URL(fileURLWithPath: "/Applications/Obsidian.app")
                case "bear":
                    URL(fileURLWithPath: "/Applications/Bear.app")
                default: nil
                }
            },
            appURLForBundleID: { id in
                if id == "com.apple.Notes" {
                    URL(fileURLWithPath: "/System/Applications/Notes.app")
                } else {
                    nil
                }
            },
            openURL: { url in
                box.openedURLs.append(url)
                return box.openURLResult
            },
            openFile: { file, app in box.openedFiles.append((file, app)) },
            openApp: { url in box.openedApps.append(url) },
            writePasteboard: { text in box.pasteboardText = text },
            tempRoot: { FileManager.default.temporaryDirectory },
            now: { sendToFixedDate },
            timeZone: { sendToFixedTimeZone }
        )
        return try makeCoreFixture(
            sendEnvironment: env,
            testName: testName
        )
    }

    /// Creates a meeting with a transcript, summary, and notes.
    private static func createPopulatedMeeting(
        fix: CoreFixture,
        title: String = "Weekly Sync",
        summary: String = "## Key points\n\n- Item one",
        notes: String = "Follow up"
    ) async throws -> UUID {
        let meetingID = try await fix.store.createMeeting(title: title)
        let result = FakeTranscriber.defaultResult
        let txID = try await fix.store.addTranscript(
            result, vocabularyUsed: [], mappedEventIdentifier: nil,
            to: meetingID
        )
        try await fix.store.setPreferredTranscript(txID, for: meetingID)
        try await fix.store.setSummary(summary, for: meetingID)
        try await fix.store.setNotes(notes, for: meetingID)
        return meetingID
    }

    // MARK: - canSend

    @Test("canSend is false when summary and notes are both empty")
    func canSendFalseWhenEmpty() async throws {
        let box = FakeBox()
        let fix = try Self.makeFixture(testName: "SendVM-Empty", box: box)
        defer { fix.cleanup() }

        let meetingID = try await Self.createPopulatedMeeting(
            fix: fix, summary: "", notes: ""
        )

        let viewModel = MeetingDetailViewModel(core: fix.core, meetingID: meetingID)
        await viewModel.load()

        #expect(!viewModel.canSend)
    }

    @Test("canSend is true when summary has content")
    func canSendTrueWithSummary() async throws {
        let box = FakeBox()
        let fix = try Self.makeFixture(testName: "SendVM-CanSend", box: box)
        defer { fix.cleanup() }

        let meetingID = try await Self.createPopulatedMeeting(fix: fix)

        let viewModel = MeetingDetailViewModel(core: fix.core, meetingID: meetingID)
        await viewModel.load()

        #expect(viewModel.canSend)
    }

    // MARK: - sendDestinations

    @Test("sendDestinations returns all three when all installed")
    func allDestinationsInstalled() async throws {
        let box = FakeBox()
        let fix = try Self.makeFixture(testName: "SendVM-Dests", box: box)
        defer { fix.cleanup() }

        let meetingID = try await Self.createPopulatedMeeting(fix: fix)
        let viewModel = MeetingDetailViewModel(core: fix.core, meetingID: meetingID)
        await viewModel.load()

        #expect(viewModel.sendDestinations == [.obsidian, .bear, .appleNotes])
    }

    // MARK: - sendSource includes unsaved edits

    @Test("sendSource includes live title, summary, and notes edits")
    func sendSourceIncludesEdits() async throws {
        let box = FakeBox()
        let fix = try Self.makeFixture(testName: "SendVM-Source", box: box)
        defer { fix.cleanup() }

        let meetingID = try await Self.createPopulatedMeeting(fix: fix)
        let viewModel = MeetingDetailViewModel(core: fix.core, meetingID: meetingID)
        await viewModel.load()

        viewModel.editableTitle = "Edited Title"
        viewModel.summaryText = "New summary"
        viewModel.notes = "New notes"

        let source = viewModel.sendSource
        #expect(source?.title == "Edited Title")
        #expect(source?.summary == "New summary")
        #expect(source?.notes == "New notes")
    }

    // MARK: - alreadySent alert

    @Test("sendTapped shows alreadySent alert when record exists")
    func alreadySentAlert() async throws {
        let box = FakeBox()
        let fix = try Self.makeFixture(testName: "SendVM-AlreadySent", box: box)
        defer { fix.cleanup() }

        let meetingID = try await Self.createPopulatedMeeting(fix: fix)

        let export = SentExport(
            destination: .obsidian,
            contentHash: "abc123",
            sentAt: sendToFixedDate
        )
        try await fix.store.recordSentExport(export, meetingID: meetingID)

        let viewModel = MeetingDetailViewModel(core: fix.core, meetingID: meetingID)
        await viewModel.load()

        await viewModel.sendTapped(.obsidian)

        if case let .alreadySent(dest, _, changed) = viewModel.sendAlert {
            #expect(dest == .obsidian)
            // Hash won't match "abc123" so changed == true
            #expect(changed)
        } else {
            Issue.record(
                "Expected .alreadySent alert, got \(String(describing: viewModel.sendAlert))"
            )
        }
    }

    // MARK: - tooLarge alert

    @Test("tooLarge alert shown when clipboard fallback activates")
    func tooLargeAlert() async throws {
        let box = FakeBox()
        let fix = try Self.makeFixture(testName: "SendVM-TooLarge", box: box)
        defer { fix.cleanup() }

        let meetingID = try await Self.createPopulatedMeeting(
            fix: fix,
            notes: String(repeating: "X", count: 600_000)
        )

        let viewModel = MeetingDetailViewModel(core: fix.core, meetingID: meetingID)
        await viewModel.load()

        await viewModel.sendTapped(.obsidian)

        if case let .tooLarge(dest) = viewModel.sendAlert {
            #expect(dest == .obsidian)
        } else {
            Issue.record(
                "Expected .tooLarge alert, got \(String(describing: viewModel.sendAlert))"
            )
        }
    }
}
