import Foundation
import Testing
@testable import UICapture

/// A call window has a way to leave and a mute control.
struct CallWindowProbeTests {
    private func button(_ label: String, role: String = "AXButton") -> NodeRecord {
        var node = NodeRecord(path: "0", depth: 1)
        node.role = role
        node.label = label
        return node
    }

    @Test func teamsMeetingWindowIsACall() {
        // Labels from the 2026-11-19 Teams meeting capture.
        let nodes = [button("Chat"), button("People"), button("Mute mic"), button("Leave"), button("Share")]
        #expect(CallWindowProbe.hasCallControls(nodes))
        #expect(CallWindowProbe.hasCallControls([button("Unmute mic"), button("Leave")]))
    }

    @Test func idleWindowsAreNotCalls() {
        // Dialpad's idle window, and Teams chat with a "Leave" in it but no mute.
        let dialpad = [button("Make a call"), button("Send a message"), button("Settings", role: "AXPopUpButton")]
        #expect(!CallWindowProbe.hasCallControls(dialpad))
        #expect(!CallWindowProbe.hasCallControls([button("Leave"), button("Chat")]))
        #expect(!CallWindowProbe.hasCallControls([button("Mute notifications"), button("Leave chat")]))
    }

    @Test func phoneAppControlsCount() {
        #expect(CallWindowProbe.hasCallControls([button("Mute"), button("Hang up")]))
        #expect(CallWindowProbe.hasCallControls([button("Unmute"), button("End call")]))
    }
}
