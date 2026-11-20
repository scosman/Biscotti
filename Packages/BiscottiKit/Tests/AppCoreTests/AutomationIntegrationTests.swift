import Automation
import BiscottiTestSupport
import DataStore
import Foundation
import Testing
@testable import AppCore

/// Recording modes, the auto-recording notification and
/// automatic export, driven through AppCore with the shared fakes.
@Suite("AppCore -- recording automation")
@MainActor
struct AutomationIntegrationTests {
    private func launch(mode: RecordingMode, name: String) async throws -> CoreFixture {
        let fix = try makeCoreFixture(
            useFakeScheduler: true,
            useImmediateDetectorClock: true,
            testName: name
        )
        try await fix.store.updateSettings { $0.onboardingComplete = true }
        fix.core.automation.update { $0.recordingMode = mode }
        await fix.core.onLaunch()
        return fix
    }

    private func emitMic(_ fix: CoreFixture, bundleID: String) {
        fix.fakeActivitySource.emit([makeAudioProcess(bundleID: bundleID, input: true, output: true)])
    }

    private func autoRecordingRequests(_ fix: CoreFixture) -> Int {
        fix.fakeNotificationCenter.addedRequests
            .count(where: { $0.content.categoryIdentifier == "biscotti.auto-recording" })
    }

    @Test("default mode is Ask, so upstream behavior is unchanged")
    func defaultIsAsk() throws {
        let fix = try makeCoreFixture(testName: "AutoDefault")
        defer { fix.cleanup() }
        #expect(fix.core.automation.settings.recordingMode == .ask)
    }

    @Test("Automatic mode records a native meeting app and posts the warning")
    func automaticRecords() async throws {
        let fix = try await launch(mode: .automatic, name: "AutoRecord")
        defer { fix.cleanup() }

        emitMic(fix, bundleID: "us.zoom.xos")
        try await pollUntil { fix.core.recording.state.isRecording && autoRecordingRequests(fix) == 1 }

        #expect(fix.core.recording.state.isRecording)
        #expect(autoRecordingRequests(fix) == 1)
    }

    @Test("Automatic mode offers instead of recording for a browser by default")
    func automaticBrowserOffers() async throws {
        let fix = try await launch(mode: .automatic, name: "AutoBrowser")
        defer { fix.cleanup() }

        emitMic(fix, bundleID: "com.google.Chrome")
        try await pollUntil { fix.core.runState == .detectedPending }

        #expect(fix.core.runState == .detectedPending)
        #expect(!fix.core.recording.state.isRecording)
        #expect(autoRecordingRequests(fix) == 0)
    }

    @Test("Paused mode ignores detection entirely")
    func pausedIgnores() async throws {
        let fix = try await launch(mode: .paused, name: "AutoPaused")
        defer { fix.cleanup() }
        let before = fix.fakeNotificationCenter.addedRequests.count

        emitMic(fix, bundleID: "us.zoom.xos")
        try await Task.sleep(for: .milliseconds(300))

        #expect(fix.core.runState == .idle)
        #expect(!fix.core.recording.state.isRecording)
        #expect(fix.fakeNotificationCenter.addedRequests.count == before)
    }

    @Test("Stop Recording on the notification stops and keeps the meeting")
    func notificationStop() async throws {
        let fix = try await launch(mode: .automatic, name: "AutoStop")
        defer { fix.cleanup() }
        emitMic(fix, bundleID: "us.zoom.xos")
        try await pollUntil { fix.core.recording.state.isRecording }
        let meetingID = try #require(fix.core.recording.state.meetingID)

        fix.notificationService.handleResponseValues(
            categoryID: "biscotti.auto-recording",
            actionID: "biscotti.action.stop-recording",
            userInfo: ["biscotti.meetingID": meetingID.uuidString]
        )
        try await pollUntil { !fix.core.recording.state.isRecording }

        #expect(!fix.core.recording.state.isRecording)
        let exists = try await fix.store.meetingExists(id: meetingID)
        #expect(exists)
    }

    @Test("Stop & Discard on the notification stops and deletes the meeting")
    func notificationDiscard() async throws {
        let fix = try await launch(mode: .automatic, name: "AutoDiscard")
        defer { fix.cleanup() }
        emitMic(fix, bundleID: "us.zoom.xos")
        try await pollUntil { fix.core.recording.state.isRecording }
        let meetingID = try #require(fix.core.recording.state.meetingID)

        fix.notificationService.handleResponseValues(
            categoryID: "biscotti.auto-recording",
            actionID: "biscotti.action.discard-recording",
            userInfo: ["biscotti.meetingID": meetingID.uuidString]
        )
        try await pollUntil { !fix.core.recording.state.isRecording }
        try await Task.sleep(for: .milliseconds(100))

        let exists = try await fix.store.meetingExists(id: meetingID)
        #expect(!exists)
    }

    @Test("Switching to Paused stops a recording in progress")
    func pausingStops() async throws {
        let fix = try await launch(mode: .ask, name: "AutoPauseStop")
        defer { fix.cleanup() }
        await fix.core.startRecording()
        #expect(fix.core.recording.state.isRecording)

        await fix.core.setRecordingMode(.paused)

        #expect(!fix.core.recording.state.isRecording)
        #expect(fix.core.automation.settings.recordingMode == .paused)
    }

    @Test("exportMeeting writes Markdown to a folder target and records the export")
    func exportToFolder() async throws {
        let fix = try makeCoreFixture(testName: "AutoExport")
        defer { fix.cleanup() }
        let folder = fix.storageRoot.appendingPathComponent("export", isDirectory: true)
        fix.core.automation.update {
            $0.exportTargets = [ExportTarget(name: "Out", kind: .folder, path: folder.path)]
        }

        let meetingID = try await fix.store.createMeeting(title: "Budget review")
        try await fix.store.setSummary("- Ship Friday", for: meetingID)

        let outcomes = try #require(await fix.core.exportMeeting(meetingID))
        let allSucceeded = outcomes.allSatisfy(\.succeeded)
        #expect(allSucceeded)
        #expect(fix.core.automation.isExported(meetingID))

        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(files.count == 1)
        let text = try String(contentsOf: folder.appendingPathComponent(files[0]), encoding: .utf8)
        #expect(text.contains("# Budget review"))
        #expect(text.contains("- Ship Friday"))
    }

    @Test("exportMeeting does nothing without enabled targets")
    func exportWithoutTargets() async throws {
        let fix = try makeCoreFixture(testName: "AutoExportNone")
        defer { fix.cleanup() }
        let meetingID = try await fix.store.createMeeting(title: "Budget review")
        try await fix.store.setSummary("x", for: meetingID)
        #expect(await fix.core.exportMeeting(meetingID) == nil)
    }
}
