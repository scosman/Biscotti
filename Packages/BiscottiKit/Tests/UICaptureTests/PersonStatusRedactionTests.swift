import Foundation
import Testing
@testable import UICapture

/// Tile descriptions keep their name and status; prose doesn't.
struct PersonStatusRedactionTests {
    @Test func tileDescriptionsAreKept() {
        let tile = "Ravi Patel, External unfamiliar, video is on, muted, hand raised"
        #expect(TextRedactor.redact(tile, role: "AXMenuItem") == tile)
        let lastFirst = "Lopez, Maria (AGENCY), External, speaking"
        #expect(TextRedactor.redact(lastFirst, role: "AXMenuItem") == lastFirst)
    }

    @Test func proseIsStillRedacted() {
        let chat = "Okay, so we should probably move the firewall change to next week, right?"
        #expect(TextRedactor.redact(chat, role: "AXMenuItem")?.hasPrefix("[redacted") == true)
        let message = "Ravi Patel, External unfamiliar, video is on, muted, hand raised"
        #expect(TextRedactor.redact(message, role: "AXStaticText")?.hasPrefix("[redacted") == true)
    }

    @Test func onlyKnownStatusesMakeAParticipantLabel() {
        #expect(TextRedactor.isPersonStatus("Ravi Patel, muted, camera off"))
        #expect(!TextRedactor.isPersonStatus("Sam Carter, call me back later"))
        #expect(!TextRedactor.isPersonStatus("Lopez, Maria, the budget is final"))
    }
}
