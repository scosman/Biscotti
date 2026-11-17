import Foundation
import Testing
@testable import DataStore

@Suite("SentExport persistence")
struct SentExportTests {
    private func makeStore() throws -> DataStore {
        try DataStore(storage: .inMemory)
    }

    private let fixedDate = Date(timeIntervalSince1970: 1_792_778_400)

    // MARK: - Round trip

    @Test("Write and read back sentExports via the transient property")
    func roundTrip() async throws {
        let store = try makeStore()
        let id = try await store.createMeeting(title: "Test")

        let export = SentExport(
            destination: .obsidian,
            contentHash: "abc123",
            sentAt: fixedDate
        )
        try await store.recordSentExport(export, meetingID: id)

        let exports = try await store.sentExports(meetingID: id)
        #expect(exports.count == 1)
        #expect(exports[0].destination == .obsidian)
        #expect(exports[0].contentHash == "abc123")
        #expect(exports[0].sentAt == fixedDate)
    }

    // MARK: - Replace for same destination

    @Test("recordSentExport replaces existing record for same destination")
    func replaceForSameDestination() async throws {
        let store = try makeStore()
        let id = try await store.createMeeting(title: "Test")

        let export1 = SentExport(destination: .obsidian, contentHash: "hash1", sentAt: fixedDate)
        try await store.recordSentExport(export1, meetingID: id)

        let laterDate = fixedDate.addingTimeInterval(3600)
        let export2 = SentExport(destination: .obsidian, contentHash: "hash2", sentAt: laterDate)
        try await store.recordSentExport(export2, meetingID: id)

        // Also add a Bear record to verify it survives
        let bearExport = SentExport(destination: .bear, contentHash: "bear1", sentAt: fixedDate)
        try await store.recordSentExport(bearExport, meetingID: id)

        let exports = try await store.sentExports(meetingID: id)
        #expect(exports.count == 2)

        let obsidian = exports.first(where: { $0.destination == .obsidian })
        #expect(obsidian?.contentHash == "hash2")
        #expect(obsidian?.sentAt == laterDate)

        let bear = exports.first(where: { $0.destination == .bear })
        #expect(bear?.contentHash == "bear1")
    }

    // MARK: - Missing meeting

    @Test("recordSentExport on missing meeting is a no-op")
    func missingMeetingNoOp() async throws {
        let store = try makeStore()
        let bogus = UUID()
        let export = SentExport(destination: .obsidian, contentHash: "abc", sentAt: fixedDate)
        // Should not throw
        try await store.recordSentExport(export, meetingID: bogus)
    }

    @Test("sentExports on missing meeting returns empty array")
    func missingMeetingReturnsEmpty() async throws {
        let store = try makeStore()
        let exports = try await store.sentExports(meetingID: UUID())
        #expect(exports.isEmpty)
    }

    // MARK: - Corrupt data

    @Test("Corrupt sentExportsData decodes as empty array")
    func corruptDataReturnsEmpty() async throws {
        let store = try makeStore()
        let id = try await store.createMeeting(title: "Test")

        // Write a valid export first so we know data was there
        let export = SentExport(destination: .obsidian, contentHash: "abc", sentAt: fixedDate)
        try await store.recordSentExport(export, meetingID: id)

        // Inject non-JSON garbage bytes into the backing Data
        try await store.read { store in
            // swiftlint:disable:next force_unwrapping
            let meeting = try store.meeting(id: id)!
            meeting.sentExportsData = Data("not valid json {{{".utf8)
        }

        // The getter's `?? []` fallback should return an empty array
        let exports = try await store.sentExports(meetingID: id)
        #expect(exports.isEmpty)
    }

    // MARK: - New meeting defaults

    @Test("New meeting has empty sentExports")
    func newMeetingReturnsEmpty() async throws {
        let store = try makeStore()
        let id = try await store.createMeeting(title: "Fresh")
        let exports = try await store.sentExports(meetingID: id)
        #expect(exports.isEmpty)
    }

    // MARK: - meetingDetail exposes sentExports

    @Test("meetingDetail includes sentExports")
    func meetingDetailExposesSentExports() async throws {
        let store = try makeStore()
        let id = try await store.createMeeting(title: "Detail test")

        let export = SentExport(destination: .appleNotes, contentHash: "notes1", sentAt: fixedDate)
        try await store.recordSentExport(export, meetingID: id)

        let detail = try await store.read { store in
            try store.meetingDetail(id: id)
        }
        #expect(detail?.sentExports.count == 1)
        #expect(detail?.sentExports.first?.destination == .appleNotes)
    }
}
