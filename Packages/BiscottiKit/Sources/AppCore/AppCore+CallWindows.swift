import Automation
import Foundation
import MeetingDetection
import Notifications
import os
import UICapture

private let callLogger = Logger(subsystem: "net.scosman.biscotti", category: "Detection")

// MARK: - Call-window detection

/// Teams joins meetings muted by default and may not open the microphone
/// until you unmute, so mic detection alone misses those meetings. Every few
/// seconds this looks for a meeting or phone app window with call controls
/// (a Leave or Hang up button and a Mute button) and treats a new one like a
/// mic detection. While a recording that saw a call window runs, the window
/// going away starts the usual auto-stop countdown.
extension AppCore {
    static let callWindowInterval: Duration = .seconds(6)

    /// A title that names one window. Zoom keeps several "untitled"
    /// windows open all the time; those can't stand for a call.
    nonisolated static func isDistinctTitle(_ title: String) -> Bool {
        title != "untitled" && !title.hasPrefix("[redacted") && !title.isEmpty
    }

    func startCallWindowDetection() {
        callWindowTask?.cancel()
        callWindowTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkCallWindows()
                do {
                    try await Task.sleep(for: Self.callWindowInterval)
                } catch {
                    return
                }
            }
        }
    }

    func checkCallWindows() async {
        let isRecording = if case .recording = runState { true } else { false }
        guard isRecording || automation.settings.recordingMode != .paused else { return }
        let candidates = uiCapture.callCandidates()
        let scans = await Task.detached(priority: .utility) {
            candidates.map { ($0, CallWindowProbe.scan(pid: $0.pid)) }
        }.value
        let inCall = scans.filter { !$0.1.callWindows.isEmpty }.map(\.0)
        let current = Set(inCall.map(\.bundleID))
        for (app, scan) in scans {
            callWindowTitles.formUnion(scan.callWindows.filter(Self.isDistinctTitle).map { "\(app.bundleID)|\($0)" })
        }
        // A call window whose controls are hidden (Zoom, mouse idle) is
        // still the call.
        let callStillOpen = scans.contains { app, scan in
            scan.windows.contains { callWindowTitles.contains("\(app.bundleID)|\($0)") }
        }
        defer { appsWithCallWindow = current }
        // A call that ended resets "skip till next meeting" for its app. A
        // call whose controls are only hidden (Zoom) hasn't ended.
        let openApps = Set(scans.filter { app, scan in
            scan.windows.contains { callWindowTitles.contains("\(app.bundleID)|\($0)") }
        }.map(\.0.bundleID))
        captionsOffered.formIntersection(current.union(openApps))
        await offerCaptionsIfNeeded(inCall)

        if case let .recording(meetingID) = runState {
            if current.isEmpty, !callStillOpen {
                callWindowMisses += 1
            } else {
                callWindowMisses = 0
                callWindowSeenWhileRecording = true
                // The call is still on screen: a countdown started because
                // the mic went quiet (muted) is wrong, so it stops.
                if autoStop?.meetingID == meetingID {
                    callLogger.notice("Call window still open: auto-stop countdown cancelled")
                    keepRecording()
                }
            }
            // Two checks in a row without the call window: the call ended.
            if callWindowSeenWhileRecording, callWindowMisses == 2, stopRecordingAutomatically {
                callLogger.notice("Call window closed: starting auto-stop countdown")
                MeetingEventLog.write("detection", "Call window closed: auto-stop countdown", bundle: rootBundleFolder(meetingID: meetingID))
                beginAutoStopCountdown(meetingID: meetingID)
            }
            return
        }
        callWindowMisses = 0
        callWindowSeenWhileRecording = false
        // Keep every tracked title whose window is still open (a call with
        // its controls hidden is still the call); drop closed ones.
        let openWindows = Set(scans.flatMap { app, scan in scan.windows.map { "\(app.bundleID)|\($0)" } })
        callWindowTitles.formIntersection(openWindows)
        guard let app = inCall.first(where: { !appsWithCallWindow.contains($0.bundleID) }) else { return }
        callLogger.notice("Call window found in \(app.bundleID, privacy: .public)")
        MeetingEventLog.write("detection", "Call window found in \(app.bundleID)")
        await handleDetectionStarted(app: DetectedApp(bundleID: app.bundleID, displayName: app.name))
    }
}

// MARK: - Offering live captions

extension AppCore {
    /// Captions are the best speaker evidence there is. Once per call, if an
    /// app's call window has them off, offer to turn them on.
    func offerCaptionsIfNeeded(_ inCall: [TargetApp]) async {
        guard automation.settings.offerCaptions else { return }
        for app in inCall where !captionsOffered.contains(app.bundleID) {
            let pid = app.pid
            let state = await Task.detached(priority: .utility) { CaptionControl.state(pid: pid) }.value
            guard state == .hidden || state == .inMoreMenu else { continue }
            captionsOffered.insert(app.bundleID)
            MeetingEventLog.write("captions", "Captions off in \(app.bundleID): offered to turn them on")
            await notifications.present(.captionsOff(bundleID: app.bundleID, appName: app.name))
        }
    }

    func turnOnCaptions(bundleID: String) async {
        guard let pid = uiCapture.callCandidates().first(where: { $0.bundleID == bundleID })?.pid else { return }
        let pressed = await Task.detached(priority: .userInitiated) { CaptionControl.turnOn(pid: pid) }.value
        MeetingEventLog.write("captions", pressed ? "Turned on captions in \(bundleID)" : "Couldn't find the Captions button in \(bundleID)")
    }
}
