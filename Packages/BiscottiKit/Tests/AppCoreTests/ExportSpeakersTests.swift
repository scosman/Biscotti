import DataStore
import Foundation
import Testing
@testable import AppCore

/// Exports list each speaker with where the name came from.
@MainActor
struct ExportSpeakersTests {
    @Test func listsSpeakersInOrderWithTheirEvidence() {
        func segment(_ speakerID: Int, _ start: Double) -> SegmentData {
            SegmentData(id: UUID(), speakerID: speakerID, speakerLabel: "Speaker \(speakerID)", startTime: start, endTime: start + 1, text: "x")
        }
        var data = MeetingExportData(
            id: UUID(), title: "T", date: Date(),
            segments: [segment(0, 0), segment(2, 1), segment(4, 2), segment(0, 3)],
            speakerNames: [0: "Sam Carter", 2: "Lee Morgan (likely)"]
        )
        data.plainSpeakerNames = [0: "Sam Carter", 2: "Lee Morgan"]
        data.speakerProvenance = [
            0: SpeakerNameProvenance(source: .microphone, confidence: .high, detail: "Your microphone was the loudest source"),
            2: SpeakerNameProvenance(source: .screen, confidence: .medium, detail: "Highlighted on screen in 4 of 9 turns")
        ]
        #expect(AppCore.speakerLines(data) == [
            "Sam Carter: \u{2713} Your mic. Your microphone was the loudest source",
            "Lee Morgan: Screen \u{00B7} Medium. Highlighted on screen in 4 of 9 turns",
            "Speaker 4: not identified"
        ])
    }
}

/// Attendees cover everyone identified, not just the invite.
@MainActor
struct ExportAttendeesTests {
    @Test func speakersJoinTheInviteList() {
        func segment(_ speakerID: Int) -> SegmentData {
            SegmentData(id: UUID(), speakerID: speakerID, speakerLabel: "Speaker \(speakerID)", startTime: 0, endTime: 1, text: "x")
        }
        var data = MeetingExportData(
            id: UUID(), title: "T", date: Date(),
            segments: [segment(0), segment(1), segment(2), segment(3)],
            speakerNames: [:]
        )
        data.plainSpeakerNames = [0: "Sam Carter", 1: "Lopez, Maria", 2: "Lee Morgan"]
        data.speakerProvenance = [2: SpeakerNameProvenance(source: .screen, confidence: .medium)]
        #expect(AppCore.attendees(invited: ["Sam Carter", "Maria Lopez"], data: data)
            == ["Sam Carter", "Maria Lopez", "Lee Morgan (likely)"])
    }
}

/// Generic window titles can't keep a call alive.
struct CallWindowTitleTests {
    @Test func onlyNamedWindowsStandForACall() {
        #expect(AppCore.isDistinctTitle("Zoom Meeting"))
        #expect(AppCore.isDistinctTitle("Fabrikam Holdings IT Project"))
        #expect(!AppCore.isDistinctTitle("untitled"))
        #expect(!AppCore.isDistinctTitle("[redacted 82 chars]"))
    }
}
