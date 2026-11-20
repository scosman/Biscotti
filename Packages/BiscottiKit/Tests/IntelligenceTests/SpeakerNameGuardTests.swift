import DataStore
import Foundation
import Testing
@testable import Intelligence

/// AI speaker guesses stay within the meeting.
struct SpeakerNameGuardTests {
    static let nameGuard = SpeakerNameGuard(
        invited: [
            PersonData(id: UUID(), name: "Kelbo, Jordan", email: "jdoe@northwind.example"),
            PersonData(id: UUID(), name: "Dana Wells -", email: nil)
        ],
        lines: ["Hey, Dale. Hey, Ravi.", "Nora's been having problems with his mic."],
        confirmedNames: ["Sam Carter", "Brooks, Daniel"]
    )

    @Test func invitedMentionedOrConfirmedNamesAreAllowed() {
        #expect(Self.nameGuard.permits(name: "Jordan Kelbo", email: nil))
        #expect(Self.nameGuard.permits(name: "Dana Wells", email: nil))
        #expect(Self.nameGuard.permits(name: "Someone", email: "jdoe@northwind.example"))
        #expect(Self.nameGuard.permits(name: "Ravi", email: nil))
        #expect(Self.nameGuard.permits(name: "Nora Hale", email: nil))
        #expect(Self.nameGuard.permits(name: "Daniel Brooks", email: nil))
    }

    @Test func aCustomerFromAnotherMeetingIsNot() {
        #expect(!Self.nameGuard.permits(name: "Tyler Grant", email: nil))
        #expect(!Self.nameGuard.permits(name: "mking@tailspin.example", email: nil))
    }

    @Test func punctuatedNamesMatchTheirSpokenParts() {
        let nameGuard = SpeakerNameGuard(invited: [], lines: ["Thanks, Marie, over to you."], confirmedNames: [])
        #expect(nameGuard.permits(name: "Anne-Marie O'Connor", email: nil))
    }
}
