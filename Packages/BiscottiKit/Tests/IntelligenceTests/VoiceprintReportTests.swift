import DataStore
import Foundation
import Testing
import VoiceprintMatching
@testable import Intelligence

// MARK: - Shared fixtures

// swiftlint:disable force_unwrapping
private let alice = PersonData(
    id: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!,
    name: "Alice", email: "alice@example.com"
)
private let bob = PersonData(
    id: UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000001")!,
    name: "Bob", email: "bob@example.com"
)
private let carol = PersonData(
    id: UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000001")!,
    name: "Carol", email: nil
)
// swiftlint:enable force_unwrapping

private func history(
    meetings: Int = 5, confirmed: Int = 2,
    perPerson: [UUID: PersonHistory] = [:]
) -> HistoryStats {
    HistoryStats(
        meetingCount: meetings,
        confirmedMeetingCount: confirmed,
        perPerson: perPerson
    )
}

// MARK: - VoiceprintReport Tests

@Suite("VoiceprintReport")
struct VoiceprintReportTests {
    @Test("empty history returns empty string")
    func emptyHistory() {
        let result = VoiceprintReport.render(
            unassignedSpeakers: [0, 1],
            speakersWithVector: [0, 1],
            matches: [:],
            history: history(meetings: 0, confirmed: 0),
            people: [:],
            invitees: [],
            assignedPersonIDs: []
        )
        #expect(result == "")
    }

    @Test("high confidence match")
    func highConfidence() {
        let matches: [Int: SpeakerMatch] = [
            0: SpeakerMatch(
                speakerID: 0, level: .high,
                candidates: [
                    PersonCandidate(
                        personID: alice.id, score: 0.9,
                        reportedDistance: 0.15,
                        countedMeetings: 4, confirmedCountedMeetings: 3,
                        isInvitee: true
                    )
                ],
                unnamedMeetingCount: 0
            )
        ]
        let result = VoiceprintReport.render(
            unassignedSpeakers: [0],
            speakersWithVector: [0],
            matches: matches,
            history: history(),
            people: [alice.id: alice],
            invitees: [alice],
            assignedPersonIDs: []
        )
        #expect(result.contains("<voiceprint_matches>"))
        #expect(result.contains("Speaker 0: High confidence match to Alice <alice@example.com>"))
        #expect(result.contains("Heard in 4 earlier meetings"))
        #expect(result.contains("3 confirmed by the user"))
    }

    @Test("medium confidence match")
    func mediumConfidence() {
        let matches: [Int: SpeakerMatch] = [
            1: SpeakerMatch(
                speakerID: 1, level: .medium,
                candidates: [
                    PersonCandidate(
                        personID: bob.id, score: 0.6,
                        reportedDistance: 0.35,
                        countedMeetings: 2, confirmedCountedMeetings: 1,
                        isInvitee: false
                    )
                ],
                unnamedMeetingCount: 0
            )
        ]
        let result = VoiceprintReport.render(
            unassignedSpeakers: [1],
            speakersWithVector: [1],
            matches: matches,
            history: history(),
            people: [bob.id: bob],
            invitees: [],
            assignedPersonIDs: []
        )
        #expect(result.contains("Speaker 1: Medium confidence match to Bob <bob@example.com>"))
    }

    @Test("low confidence match with singular meeting")
    func lowConfidenceSingular() {
        let matches: [Int: SpeakerMatch] = [
            0: SpeakerMatch(
                speakerID: 0, level: .low,
                candidates: [
                    PersonCandidate(
                        personID: alice.id, score: 0.3,
                        reportedDistance: 0.48,
                        countedMeetings: 1, confirmedCountedMeetings: 0,
                        isInvitee: false
                    )
                ],
                unnamedMeetingCount: 0
            )
        ]
        let result = VoiceprintReport.render(
            unassignedSpeakers: [0],
            speakersWithVector: [0],
            matches: matches,
            history: history(meetings: 1, confirmed: 0),
            people: [alice.id: alice],
            invitees: [],
            assignedPersonIDs: []
        )
        #expect(result.contains("1 earlier meeting"))
        #expect(result.contains("Heard in 1 earlier meeting"))
    }

    @Test("ambiguous match with three candidates")
    func ambiguousThreeWay() {
        let matches: [Int: SpeakerMatch] = [
            0: SpeakerMatch(
                speakerID: 0, level: .ambiguous,
                candidates: [
                    PersonCandidate(
                        personID: alice.id, score: 0.5,
                        reportedDistance: 0.3,
                        countedMeetings: 3, confirmedCountedMeetings: 2,
                        isInvitee: true
                    ),
                    PersonCandidate(
                        personID: bob.id, score: 0.45,
                        reportedDistance: 0.32,
                        countedMeetings: 2, confirmedCountedMeetings: 1,
                        isInvitee: false
                    ),
                    PersonCandidate(
                        personID: carol.id, score: 0.4,
                        reportedDistance: 0.34,
                        countedMeetings: 1, confirmedCountedMeetings: 0,
                        isInvitee: false
                    )
                ],
                unnamedMeetingCount: 0
            )
        ]
        let result = VoiceprintReport.render(
            unassignedSpeakers: [0],
            speakersWithVector: [0],
            matches: matches,
            history: history(),
            people: [alice.id: alice, bob.id: bob, carol.id: carol],
            invitees: [alice],
            assignedPersonIDs: []
        )
        #expect(result.contains("close to more than one known person"))
        #expect(result.contains("Alice <alice@example.com>"))
        #expect(result.contains("Bob <bob@example.com>"))
        #expect(result.contains("Carol (no email)"))
    }

    @Test("none match with unnamed meetings")
    func noneWithUnnamed() {
        let matches: [Int: SpeakerMatch] = [
            0: SpeakerMatch(
                speakerID: 0, level: .none,
                candidates: [],
                unnamedMeetingCount: 3
            )
        ]
        let result = VoiceprintReport.render(
            unassignedSpeakers: [0],
            speakersWithVector: [0],
            matches: matches,
            history: history(),
            people: [:],
            invitees: [],
            assignedPersonIDs: []
        )
        #expect(result.contains("unnamed speaker from 3 earlier meetings"))
    }

    @Test("none match without unnamed meetings")
    func noneNoUnnamed() {
        let matches: [Int: SpeakerMatch] = [
            0: SpeakerMatch(
                speakerID: 0, level: .none,
                candidates: [],
                unnamedMeetingCount: 1
            )
        ]
        let result = VoiceprintReport.render(
            unassignedSpeakers: [0],
            speakersWithVector: [0],
            matches: matches,
            history: history(),
            people: [:],
            invitees: [],
            assignedPersonIDs: []
        )
        #expect(result.contains("no match to any earlier speaker"))
    }

    @Test("speaker without vector")
    func noVector() {
        let result = VoiceprintReport.render(
            unassignedSpeakers: [0],
            speakersWithVector: [],
            matches: [:],
            history: history(),
            people: [:],
            invitees: [],
            assignedPersonIDs: []
        )
        #expect(result.contains("no voiceprint available for this speaker"))
    }
}

// MARK: - VoiceprintReport Invitee Tests

@Suite("VoiceprintReport invitees")
struct VoiceprintReportInviteeTests {
    @Test("not-invited marker when invitees present")
    func notInvitedMarker() {
        let matches: [Int: SpeakerMatch] = [
            0: SpeakerMatch(
                speakerID: 0, level: .high,
                candidates: [
                    PersonCandidate(
                        personID: bob.id, score: 0.9,
                        reportedDistance: 0.15,
                        countedMeetings: 4, confirmedCountedMeetings: 3,
                        isInvitee: false
                    )
                ],
                unnamedMeetingCount: 0
            )
        ]
        let result = VoiceprintReport.render(
            unassignedSpeakers: [0],
            speakersWithVector: [0],
            matches: matches,
            history: history(),
            people: [bob.id: bob],
            invitees: [alice],
            assignedPersonIDs: []
        )
        #expect(result.contains("(not invited)"))
    }

    @Test("invitee section with history")
    func inviteeSection() {
        let perPerson = [alice.id: PersonHistory(meetings: 3, confirmedMeetings: 2)]
        let result = VoiceprintReport.render(
            unassignedSpeakers: [0],
            speakersWithVector: [0],
            matches: [:],
            history: history(perPerson: perPerson),
            people: [alice.id: alice],
            invitees: [alice],
            assignedPersonIDs: []
        )
        #expect(result.contains("Invitees with voiceprint history:"))
        #expect(result.contains("alice@example.com: 3 earlier meetings"))
    }

    @Test("assigned person excluded from invitee section")
    func assignedExcludedFromInvitees() {
        let perPerson = [alice.id: PersonHistory(meetings: 3, confirmedMeetings: 2)]
        let result = VoiceprintReport.render(
            unassignedSpeakers: [1],
            speakersWithVector: [1],
            matches: [:],
            history: history(perPerson: perPerson),
            people: [alice.id: alice],
            invitees: [alice],
            assignedPersonIDs: [alice.id]
        )
        #expect(!result.contains("alice@example.com"))
    }

    @Test("invitee with no email excluded from invitee section")
    func inviteeNoEmail() {
        let result = VoiceprintReport.render(
            unassignedSpeakers: [0],
            speakersWithVector: [0],
            matches: [:],
            history: history(),
            people: [:],
            invitees: [carol],
            assignedPersonIDs: []
        )
        #expect(!result.contains("Invitees with voiceprint history:"))
    }
}

// MARK: - IntelligencePrompts Voiceprint Tests

@Suite("IntelligencePrompts voiceprint placement")
struct IntelligencePromptsVoiceprintTests {
    @Test("voiceprintBlock placed between mapping and transcript")
    func blockPlacement() {
        let detail = MeetingDetailData(
            id: UUID(), title: "Test", date: Date(),
            duration: nil, hasAudio: false,
            preferredTranscript: nil
        )
        let block = "<voiceprint_matches>\nTest data\n</voiceprint_matches>"
        let result = IntelligencePrompts.analysisFirstUser(
            detail: detail, human: [:],
            voiceprintBlock: block,
            transcriptSpeakerLabeled: "Speaker 0: Hello"
        )

        let blockRange = result.range(of: "<voiceprint_matches>")
        let transcriptRange = result.range(of: "<transcript>")
        #expect(blockRange != nil)
        #expect(transcriptRange != nil)
        if let bRange = blockRange, let tRange = transcriptRange {
            #expect(bRange.lowerBound < tRange.lowerBound)
        }
    }

    @Test("empty voiceprintBlock does not insert a voiceprint data section")
    func emptyBlockOmitted() {
        let detail = MeetingDetailData(
            id: UUID(), title: "Test", date: Date(),
            duration: nil, hasAudio: false,
            preferredTranscript: nil
        )
        let result = IntelligencePrompts.analysisFirstUser(
            detail: detail, human: [:],
            transcriptSpeakerLabeled: "Speaker 0: Hello"
        )
        #expect(!result.contains("<voiceprint_matches>\n"))
    }

    @Test("speakerTaskInstructions includes voiceprint guidance")
    func instructionsIncludeVoiceprintGuidance() {
        let instructions = IntelligencePrompts.speakerTaskInstructions
        #expect(instructions.contains("<voiceprint_matches>"))
        #expect(instructions.contains("Voice evidence and transcript evidence"))
    }

    @Test("inviteeBlock marks current user")
    func currentUserMarker() {
        let organizer = PersonData(
            id: UUID(), name: "Me", email: "me@example.com",
            isCurrentUser: true
        )
        let attendee = PersonData(
            id: UUID(), name: "Other", email: "other@example.com"
        )
        let calendar = CalendarContextData(
            organizer: organizer,
            attendees: [attendee]
        )
        let detail = MeetingDetailData(
            id: UUID(), title: "Test", date: Date(),
            duration: nil, hasAudio: false,
            preferredTranscript: nil,
            calendar: calendar
        )
        let block = IntelligencePrompts.meetingDetailsBlock(detail)
        #expect(block.contains("(the person who recorded this meeting)"))
        #expect(block.contains("Me <me@example.com> (the person who recorded this meeting)"))
    }
}
