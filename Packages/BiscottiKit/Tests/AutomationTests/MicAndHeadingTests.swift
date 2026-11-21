import Foundation
import Testing
@testable import Automation

@Suite("MicChooser")
struct MicChooserTests {
    let builtIn = MicCandidate(uid: "BuiltInMic", name: "MacBook Pro Microphone", isHeadset: false, connection: .builtIn, isSystemDefault: true)
    let airPods = MicCandidate(uid: "AirPods-UID", name: "Sam's AirPods Pro", isHeadset: true, connection: .bluetooth)
    let jabra = MicCandidate(uid: "Jabra-UID", name: "Jabra Evolve2", isHeadset: true, connection: .usb)
    let shure = MicCandidate(uid: "Shure-UID", name: "Shure MV7", isHeadset: false, connection: .usb)
    let dock = MicCandidate(uid: "OWC-UID", name: "OWC Thunderbolt 3 Audio Device", isHeadset: false, connection: .usb)

    @Test("empty priority means the system default")
    func sameAsSystem() {
        #expect(MicChooser.choose(priority: [], connected: [builtIn, airPods]) == nil)
    }

    @Test("Any headset picks a connected headset, else falls through to system")
    func anyHeadset() {
        #expect(MicChooser.choose(priority: [.anyHeadset], connected: [builtIn, airPods]) == "AirPods-UID")
        #expect(MicChooser.choose(priority: [.anyHeadset], connected: [builtIn, shure]) == nil)
    }

    @Test("Any headset prefers the headset that is already the system default")
    func headsetMatchesSystem() {
        let jabraDefault = MicCandidate(uid: "Jabra-UID", name: "Jabra", isHeadset: true, isSystemDefault: true)
        #expect(MicChooser.choose(priority: [.anyHeadset], connected: [airPods, jabraDefault]) == "Jabra-UID")
    }

    @Test("the 2026-11-18 case: AirPods leave mid-recording and a dock is connected")
    func airPodsLeaveWithDock() {
        // Any headset must not pick the dock: it falls back to the system default.
        #expect(MicChooser.choose(priority: [.anyHeadset], connected: [builtIn, dock]) == nil)
        #expect(MicChooser.choose(priority: [.anyHeadset], connected: [builtIn, dock, airPods]) == "AirPods-UID")
    }

    @Test("Any Bluetooth and Any USB match by connection")
    func connectionGroups() {
        #expect(MicChooser.choose(priority: [.anyBluetooth], connected: [builtIn, dock, airPods]) == "AirPods-UID")
        #expect(MicChooser.choose(priority: [.anyBluetooth], connected: [builtIn, dock]) == nil)
        #expect(MicChooser.choose(priority: [.anyUSB], connected: [builtIn, airPods, shure, dock]) == "Shure-UID")
        #expect(MicChooser.choose(priority: [.anyUSB, .anyBluetooth], connected: [builtIn, airPods]) == "AirPods-UID")
        #expect(MicPriorityEntry.groups == [.anyHeadset, .anyBluetooth, .anyUSB])
    }

    @Test("a specific device wins when connected and is skipped when not")
    func specificDevice() {
        let priority: [MicPriorityEntry] = [.device(uid: "Shure-UID", name: "Shure MV7"), .anyHeadset]
        #expect(MicChooser.choose(priority: priority, connected: [builtIn, airPods, shure]) == "Shure-UID")
        #expect(MicChooser.choose(priority: priority, connected: [builtIn, airPods]) == "AirPods-UID")
        #expect(MicChooser.choose(priority: priority, connected: [builtIn]) == nil)
    }

    @Test("without switch-up, the current device is kept while connected")
    func stayPut() {
        let priority: [MicPriorityEntry] = [.device(uid: "AirPods-UID", name: "AirPods"), .anyHeadset]
        #expect(MicChooser.choose(priority: priority, connected: [airPods, jabra], current: "Jabra-UID", allowSwitchUp: false) == "Jabra-UID")
        #expect(MicChooser.choose(priority: priority, connected: [airPods, jabra], current: "Jabra-UID", allowSwitchUp: true) == "AirPods-UID")
        // Current device gone: fall back to the list.
        #expect(MicChooser.choose(priority: priority, connected: [airPods], current: "Jabra-UID", allowSwitchUp: false) == "AirPods-UID")
    }

    @Test("policy box tracks the current device and resets between recordings")
    func policyBox() {
        let box = MicPolicyBox()
        box.update(priority: [.device(uid: "AirPods-UID", name: "AirPods"), .anyHeadset], allowSwitchUp: false)
        #expect(box.choose(connected: [builtIn, jabra]) == "Jabra-UID")
        #expect(box.lastChosenName == "Jabra Evolve2")
        // AirPods arrive mid-recording: no switch-up, keep Jabra.
        #expect(box.choose(connected: [builtIn, jabra, airPods]) == "Jabra-UID")
        box.resetCurrent()
        // Next recording starts from the top.
        #expect(box.choose(connected: [builtIn, jabra, airPods]) == "AirPods-UID")
    }

    @Test("system default choice reports the default device's name")
    func systemName() {
        let box = MicPolicyBox()
        #expect(box.choose(connected: [builtIn, airPods]) == nil)
        #expect(box.lastChosenName == "MacBook Pro Microphone")
    }

    @Test("priority entries and settings round-trip")
    func codable() throws {
        let settings = AutomationSettings(micPriority: [.device(uid: "X", name: "Shure"), .anyHeadset], micSwitchUp: false)
        let data = try JSONEncoder().encode(settings)
        let back = try JSONDecoder().decode(AutomationSettings.self, from: data)
        #expect(back.micPriority == settings.micPriority)
        #expect(back.micSwitchUp == false)
        #expect(AutomationSettings().micPriority.isEmpty)
    }
}

@Suite("Export heading cleanup")
struct HeadingCleanupTests {
    @Test("a repeated section heading is removed at any level")
    func strips() {
        #expect(MeetingMarkdown.stripLeadingHeading("Summary", from: "## Summary\nThe meeting...") == "The meeting...")
        #expect(MeetingMarkdown.stripLeadingHeading("Summary", from: "# summary\n\nText") == "Text")
        #expect(MeetingMarkdown.stripLeadingHeading("Summary", from: "## Action Items\n- x") == "## Action Items\n- x")
        #expect(MeetingMarkdown.stripLeadingHeading("Summary", from: "Plain text") == "Plain text")
    }

    @Test("rendered export has one Summary heading and keeps sub-sections")
    func rendered() {
        let meeting = ExportableMeeting(
            id: UUID(), title: "Test", date: Date(timeIntervalSince1970: 0),
            summary: "## Summary\nThe meeting was a test.\n\n## Action Items\n- [ ] Finish"
        )
        let text = MeetingMarkdown.render(meeting, timeZone: TimeZone(identifier: "UTC") ?? .current)
        #expect(text.components(separatedBy: "## Summary").count == 2)
        #expect(text.contains("## Summary\n\nThe meeting was a test.\n\n## Action Items"))
    }
}
