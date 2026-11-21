import AudioCapture
import Automation
import DataStore
import Formatting
import Foundation
import ImportExport
import MeetingDetection
import os
import TranscriptionService
import UICapture

// Recording modes, auto-record, screen-lock stop, automatic
// export and retention grooming. Kept in its own file so upstream changes
// to AppCore.swift merge with as few conflicts as possible.

private let automationLogger = Logger(subsystem: "net.scosman.biscotti", category: "Automation")

// MARK: - Recording mode

public extension AppCore {
    /// Changes the recording mode. Pausing also stops any recording in
    /// progress and clears pending "Meeting detected" banners, so nothing
    /// is captured while paused.
    func setRecordingMode(_ mode: RecordingMode) async {
        automation.update { $0.recordingMode = mode }
        automationLogger.info("Recording mode set to \(mode.rawValue, privacy: .public)")
        guard mode == .paused else { return }
        // A recording still starting up is cancelled too; its generation
        // check stops it before (or right after) the recorder starts.
        if recordingStartup == .loading { cancelRecordingStartup() }
        await notifications.cancelAdHocDetected()
        if recording.state.isRecording {
            await stopRecording()
        }
    }
}

// MARK: - UI capture

extension AppCore {
    /// Ends per-recording fork state: the tied UI capture, and the mic
    /// policy's "current device" so the next recording starts from the top.
    func recordingDidStop() {
        uiCapture.stopForRecording()
        automation.micPolicy.resetCurrent()
    }

    /// Starts the meeting UI capture alongside a new recording, when enabled.
    /// Call-window evidence starts fresh with each recording, so a call
    /// still going on can establish it again for the new one.
    func recordingDidStart(meetingID: UUID) {
        callWindowMisses = 0
        callWindowSeenWhileRecording = false
        callWindowTitles = []
        guard automation.settings.captureMeetingUI else { return }
        uiCapture.excludedApps = Set(automation.settings.captureExcludedApps)
        uiCapture.startForRecording(
            meetingID: meetingID, startedAt: recording.state.startDate,
            bundleFolder: rootBundleFolder(meetingID: meetingID)
        )
    }
}

public extension AppCore {
    /// Starts a UI capture, tagging it with the recording in progress (if
    /// any) so it can be lined up with that meeting's audio later.
    func startUICapture() {
        let state = recording.state
        uiCapture.start(
            recordingMeetingID: state.isRecording ? state.meetingID : nil,
            recordingStartedAt: state.isRecording ? state.startDate : nil
        )
    }
}

// MARK: - Microphones

public extension AppCore {
    /// Connected input devices, for the mic priority list in Settings.
    func connectedMicrophones() -> [MicCandidate] {
        InputDevices.connected().map(\.micCandidate)
    }

    /// The mic the most recent recording started on (or switched to).
    var lastMicrophoneName: String? {
        automation.micPolicy.lastChosenName
    }
}

// MARK: - Detection

extension AppCore {
    func detectionResponse(for app: DetectedApp) -> DetectionResponse {
        let settings = automation.settings
        return DetectionPolicy.response(
            mode: settings.recordingMode,
            bundleID: app.bundleID,
            autoRecordInBrowsers: settings.autoRecordInBrowsers,
            monitorForMeetings: monitorForMeetings
        )
    }

    /// Starts recording for a detected meeting and posts the warning
    /// notification with Stop and Discard actions.
    func autoStartRecording(app: DetectedApp) async {
        automationLogger.notice("Auto-recording \(app.bundleID, privacy: .public)")
        MeetingEventLog.write("detection", "Auto-recording started for \(app.bundleID)")
        await startRecording()
        guard recording.state.isRecording, let meetingID = recording.state.meetingID else {
            automationLogger.error("Auto-record for \(app.bundleID, privacy: .public) did not start")
            return
        }
        await notifications.present(
            .autoRecordingStarted(meetingID: meetingID, appName: app.displayName)
        )
    }

    /// Handles Stop / Stop & Discard from the auto-recording notification.
    /// Ignored when that recording already ended (a stale banner).
    func stopAutoRecording(meetingID: UUID, discard: Bool) async {
        guard recording.state.isRecording, recording.state.meetingID == meetingID else {
            await notifications.cancelAutoRecordingStarted(meetingID: meetingID)
            return
        }
        await stopRecording()
        if discard {
            automationLogger.info("Discarding auto-recorded meeting \(meetingID, privacy: .public)")
            await deleteMeeting(meetingID: meetingID)
        }
    }
}

// MARK: - Background services

extension AppCore {
    /// Started from `startBackgroundServices`.
    func startAutomationServices() {
        installSpeakerNaming()
        startCallWindowDetection()
        Task { [weak self] in await self?.removeJunkPeople() }
        uiCapture.micUsersProvider = {
            Set(AudioProcess.current().filter(\.isRunningInput).compactMap(\.bundleID))
        }
        Task { [weak self] in await self?.checkPermissionsAtLaunch() }
        screenLockTask?.cancel()
        screenLockTask = Task { [weak self] in
            for await _ in ScreenLock.center.notifications(named: ScreenLock.lockedNotification) {
                guard let self else { return }
                await handleScreenLocked()
            }
        }

        retentionTask?.cancel()
        retentionTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.runRetentionPass()
                do {
                    try await Task.sleep(for: .seconds(6 * 3600))
                } catch {
                    return
                }
            }
        }
    }

    private func handleScreenLocked() async {
        guard automation.settings.stopOnScreenLock, recording.state.isRecording else { return }
        automationLogger.info("Screen locked: stopping recording")
        await stopRecording()
    }

    /// Runs after transcription and AI enhancements finish for a meeting.
    func afterPostProcessing(meetingID: UUID, reTranscribed: Bool = false) async {
        // A re-transcription uses the choice made when it was started, else
        // the setting; a first transcription always exports.
        var choice: ReExportChoice = .replace
        if reTranscribed {
            choice = automation.pendingReExport.removeValue(forKey: meetingID)
                ?? automation.settings.reTranscribeExport.automaticChoice
                ?? .replace
        }
        switch choice {
        case .skip:
            automationLogger.info("Export skipped after re-transcribing, as chosen")
        case .keepBoth:
            await exportMeeting(meetingID, keepingOld: true)
        case .replace:
            await exportMeeting(meetingID)
        }
        await runRetentionPass()
    }
}

// MARK: - Export

public extension AppCore {
    /// Whether re-transcribing this meeting should ask about exports, and
    /// whether it has an export file that would be replaced.
    func reExportQuestion(for meetingID: UUID) -> (ask: Bool, hasExistingFile: Bool) {
        let targets = automation.settings.enabledExportTargets
        guard !targets.isEmpty, automation.settings.reTranscribeExport == .ask else { return (false, false) }
        let existing = !MeetingExporter.existingExports(meetingID: meetingID, in: targets).isEmpty
        return (true, existing)
    }

    /// What to do with an existing export after speaker names
    /// change by hand. Nil when there's nothing to do (no export targets or
    /// no export file yet, or the setting says don't export); `.some(nil)`
    /// when the setting says ask.
    func exportChoiceAfterNameChange(for meetingID: UUID) -> ReExportChoice?? {
        let targets = automation.settings.enabledExportTargets
        guard !targets.isEmpty, !MeetingExporter.existingExports(meetingID: meetingID, in: targets).isEmpty else {
            return nil
        }
        let automatic = automation.settings.reTranscribeExport.automaticChoice
        if automatic == .skip { return nil }
        return .some(automatic)
    }

    /// Re-exports after a name change, as chosen.
    func exportAfterNameChange(_ meetingID: UUID, choice: ReExportChoice) async {
        switch choice {
        case .replace: _ = await exportMeeting(meetingID)
        case .keepBoth: _ = await exportMeeting(meetingID, keepingOld: true)
        case .skip: break
        }
    }

    /// Re-transcribes with the user's export choice for when it finishes.
    func enqueueReTranscription(meetingID: UUID, exportChoice: ReExportChoice, config: TranscriptionConfig? = nil) {
        automation.pendingReExport[meetingID] = exportChoice
        enqueueReTranscription(meetingID: meetingID, config: config)
    }

    /// Exports one meeting to every enabled target. Returns nil when there
    /// are no enabled targets or nothing to export yet.
    @discardableResult
    func exportMeeting(_ meetingID: UUID, keepingOld: Bool = false, notify: Bool = true) async -> [ExportOutcome]? {
        let targets = automation.settings.enabledExportTargets
        guard !targets.isEmpty, let meeting = await exportableMeeting(meetingID) else { return nil }

        let existing = MeetingExporter.existingExports(meetingID: meetingID, in: targets)
        var keptNames: [String] = []
        if keepingOld, !existing.isEmpty {
            do {
                keptNames = try MeetingExporter.preserveExistingExports(meetingID: meetingID, in: targets)
                    .map(\.lastPathComponent)
            } catch {
                // The user asked to keep the old export. If it couldn't be set
                // aside, don't export over it.
                let message = "Couldn't keep the old export, so it wasn't replaced: \(error.localizedDescription)"
                automationLogger.error("Export: \(message, privacy: .public)")
                automation.lastExportStatus = ExportStatus(
                    date: Date(), meetingTitle: meeting.title, failures: [message], detail: message
                )
                return nil
            }
        }
        let outcomes = await exporter.export(meeting, to: targets)
        let failures = outcomes.compactMap { outcome in
            outcome.error.map { "\(outcome.targetName): \($0)" }
        }
        let warnings = outcomes.compactMap { outcome in
            outcome.pushWarning.map { "\(outcome.targetName): \($0)" }
        }
        // Each target that got the file counts; retention waits for all of them.
        automation.markExported(meetingID, targets: outcomes.filter(\.succeeded).map(\.targetID))
        let detail = Self.exportDetail(
            failures: failures, replaced: !existing.isEmpty && keptNames.isEmpty,
            kept: keptNames, targets: targets.map(\.name)
        )
        let status = ExportStatus(
            date: Date(), meetingTitle: meeting.title, failures: failures + warnings, detail: detail
        )
        automation.lastExportStatus = status
        for message in failures + warnings {
            automationLogger.error("Export: \(message, privacy: .public)")
        }
        automationLogger.info("Export \(meetingID, privacy: .public): \(detail, privacy: .public)")
        if notify, automation.settings.notifyOnExport {
            await notifications.present(
                .exportUpdated(meetingID: meetingID, meetingTitle: meeting.title, detail: detail)
            )
        }
        return outcomes
    }

    /// What an export did, in words: "Replaced the existing file in
    /// Transcriptions." / "Wrote a new file to Transcriptions." / "Kept the
    /// old file as <name> and wrote the new one to Transcriptions."
    static func exportDetail(failures: [String], replaced: Bool, kept: [String], targets: [String]) -> String {
        if !failures.isEmpty {
            return "Failed: " + failures.joined(separator: "; ")
        }
        let places = targets.joined(separator: ", ")
        if let first = kept.first {
            return "Kept the old file as \u{201C}\(first)\u{201D} and wrote the new one to \(places)."
        }
        return replaced ? "Replaced the existing file in \(places)." : "Wrote a new file to \(places)."
    }

    /// Exports every meeting that has text. Used by "Export All Now".
    /// Returns the number of meetings exported to every target.
    @discardableResult
    func exportAllMeetings() async -> Int {
        let ids = await (try? store.meetingIDsForExport()) ?? []
        var exported = 0
        for id in ids {
            if let outcomes = await exportMeeting(id, notify: false), outcomes.allSatisfy(\.succeeded) {
                exported += 1
            }
        }
        return exported
    }

    /// Who each speaker is and how sure the app is, in order
    /// of first appearance. Unnamed voices are listed too.
    static func speakerLines(_ data: MeetingExportData) -> [String] {
        var order: [Int] = []
        for segment in data.segments {
            if let speakerID = segment.speakerID, !order.contains(speakerID) { order.append(speakerID) }
        }
        return order.map { speakerID in
            guard let name = data.plainSpeakerNames[speakerID] else {
                return "Speaker \(speakerID): not identified"
            }
            guard let provenance = data.speakerProvenance[speakerID] else { return name }
            var line = "\(name): \(provenance.badgeText)"
            if let detail = provenance.detail, !detail.isEmpty { line += ". \(detail)" }
            return line
        }
    }

    /// Everyone in the meeting: the invite's attendees, then
    /// every named speaker not already listed. Speakers the app isn't sure
    /// of keep their "(likely)"/"(unsure)"/"(guess)" mark.
    static func attendees(invited: [String], data: MeetingExportData) -> [String] {
        var result = invited
        var seen = Set(invited.map(PersonAlias.key))
        let order = data.segments.compactMap(\.speakerID)
        var speakers: [Int] = []
        for speakerID in order where !speakers.contains(speakerID) {
            speakers.append(speakerID)
        }
        for speakerID in speakers {
            guard let name = data.plainSpeakerNames[speakerID], seen.insert(PersonAlias.key(name)).inserted else { continue }
            result.append(data.speakerProvenance[speakerID]?.label(name) ?? name)
        }
        return result
    }

    /// The transcript as exported: unclear lines marked, with a one-line
    /// audio-quality note on top when there are any (for technicians).
    static func exportTranscript(_ segments: [SegmentData], names: [Int: String]) -> String {
        let body = TranscriptTextFormatting.render(segments, names: names, markUnclear: true)
        guard let note = TranscriptTextFormatting.unclearSummary(segments, names: names) else { return body }
        return "> \(note)\n\n\(body)"
    }

    private func exportableMeeting(_ meetingID: UUID) async -> ExportableMeeting? {
        guard let detail = try? await store.meetingDetail(id: meetingID),
              let data = try? await store.exportData(for: [meetingID]).first
        else { return nil }

        let source = ExportSource(detail: detail)
        var meeting = ExportableMeeting(
            id: meetingID,
            title: detail.title,
            date: detail.date,
            durationMinutes: source.durationMinutes,
            attendees: Self.attendees(invited: source.attendees, data: data),
            tags: source.tags,
            summary: detail.summary,
            notes: detail.notes,
            transcript: Self.exportTranscript(data.segments, names: data.speakerNames)
        )
        meeting.speakers = Self.speakerLines(data)
        return meeting.hasContent ? meeting : nil
    }
}

// MARK: - Retention

public extension AppCore {
    /// Applies the retention policy once. Skips the meeting being recorded
    /// and anything queued or running in post-processing.
    func runRetentionPass() async {
        groomCaptureFiles()
        let settings = automation.settings
        let policy = settings.retention
        guard policy.audioRetentionDays != nil || policy.meetingRetentionDays != nil else { return }

        let plan = await RetentionPlanner.plan(
            candidates: retentionCandidates(),
            policy: policy,
            now: Date(),
            protected: protectedMeetingIDs(),
            hasEnabledExportTargets: !settings.enabledExportTargets.isEmpty
        )
        guard !plan.isEmpty else { return }

        for meetingID in plan.audioToDelete {
            await deleteAudio(meetingID: meetingID)
        }
        var deletedMeetings: [UUID] = []
        for meetingID in plan.meetingsToDelete {
            // Re-checked here: the plan is a snapshot, and a meeting can be
            // queued for transcription while earlier deletions run.
            guard !protectedMeetingIDs().contains(meetingID) else { continue }
            let deleted = await deleteSingleMeetingInternal(meetingID: meetingID)
            guard deleted else { continue }
            deletedMeetings.append(meetingID)
        }
        automation.forgetExports(deletedMeetings)
        await reloadSummaries()

        let summary = "Removed audio from \(plan.audioToDelete.count) and deleted \(deletedMeetings.count) meeting(s)"
        automation.lastRetentionSummary = "\(summary) on \(Date().formatted(date: .abbreviated, time: .shortened))."
        automationLogger.info("Retention: \(summary, privacy: .public)")
    }

    /// Shows the launch permission prompt (`missingPermissions`) when
    /// anything Biscotti needs isn't granted.
    func checkPermissionsAtLaunch() async {
        guard automation.isLive else { return }
        await refreshAllPermissions()
        let missing = permissionsNeedingAttention
        guard !missing.isEmpty else { return }
        automationLogger.info("Permissions missing at launch: \(missing.map(\.title).joined(separator: ", "), privacy: .public)")
        automation.missingPermissions = missing.map(\.rawValue)
    }

    /// Deletes meeting-window capture files older than the setting allows.
    /// They are only needed until the meeting's speakers have been named.
    func groomCaptureFiles() {
        let days = automation.settings.captureKeepDays
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        let folders = Set([uiCapture.folder, UICaptureController.defaultFolder].compactMap(\.self))
        var removed = 0
        for folder in folders {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey]
            )) ?? []
            for file in files where file.lastPathComponent.hasPrefix("ui-capture") && file.pathExtension == "jsonl" {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                guard let modified, modified < cutoff, uiCapture.currentFile != file else { continue }
                if (try? FileManager.default.removeItem(at: file)) != nil { removed += 1 }
            }
        }
        if removed > 0 {
            automationLogger.info("Retention: removed \(removed) capture file(s)")
        }
    }

    private func retentionCandidates() async -> [RetentionCandidate] {
        let summaries = await (try? store.meetingSummaries(limit: nil)) ?? []
        var candidates: [RetentionCandidate] = []
        for summary in summaries {
            let audio = try? await store.storedAudioFileRefs(meetingID: summary.id)
            candidates.append(RetentionCandidate(
                id: summary.id,
                date: summary.date,
                hasTranscript: summary.hasTranscript,
                hasAudio: audio?.present ?? false,
                isExported: automation.isExported(summary.id)
            ))
        }
        return candidates
    }

    private func protectedMeetingIDs() -> Set<UUID> {
        var ids = Set(postProcessing.waiting.map(\.meetingID))
        if let running = postProcessing.running {
            ids.insert(running.meetingID)
        }
        if recording.state.isRecording, let current = recording.state.meetingID {
            ids.insert(current)
        }
        return ids
    }

    /// Deletes a meeting's audio files and marks them absent. The meeting,
    /// transcript, summary and notes stay.
    private func deleteAudio(meetingID: UUID) async {
        let paths = await (try? store.audioFilePaths(meetingID: meetingID)) ?? []
        // The lookup awaited: a recording or transcription may have started
        // on this meeting since the plan was made. Check again right before
        // deleting, with no suspension point in between.
        guard !protectedMeetingIDs().contains(meetingID) else { return }
        deleteRecordingFiles(paths)
        do {
            try await store.markAudioPresence(meetingID: meetingID)
        } catch {
            automationLogger.error("Retention: markAudioPresence failed for \(meetingID, privacy: .public): \(error)")
        }
    }
}
