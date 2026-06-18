import AudioCapture
import DataStore
import Foundation
import os.log
import Permissions

/// App-level recording lifecycle on top of the `AudioCapture` engine.
///
/// Owns storage paths, DataStore wiring (create meeting, attach audio refs,
/// mark presence), system-audio denial inference, elapsed-time pumping, and
/// orphan recovery. All heavy audio work is delegated to the injected
/// `RecorderControlling` engine; this controller runs on `@MainActor` and
/// exposes observable state for the UI.
@MainActor @Observable
public final class RecordingController {
    // MARK: - Published state

    /// The current recording state (isRecording, elapsed, meetingID).
    public private(set) var state: RecordingState = .idle

    /// `true` if the engine inferred that system audio capture was denied.
    public private(set) var systemAudioWarning: Bool = false

    /// The last error from a start or stop attempt. Cleared on next start.
    public private(set) var lastError: RecordingError?

    /// In-memory notes captured during the current recording session.
    /// Oldest-first (insertion order). Reset on `start()`, seeded on `stop()`.
    public private(set) var notes: [MeetingNote] = []

    // MARK: - Dependencies

    private let store: DataStore
    private let permissions: Permissions
    private let storageRoot: URL
    private let makeRecorder: @Sendable () -> any RecorderControlling

    /// How long to wait before checking system-audio denial (injectable for tests).
    private let denialCheckDelay: Duration

    // MARK: - Session state

    private var recorder: (any RecorderControlling)?
    private var stateStreamTask: Task<Void, Never>?
    private var denialCheckTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?

    private static let logger = Logger(
        subsystem: "net.scosman.biscotti",
        category: "RecordingController"
    )

    /// Name of the marker file written into each recording directory.
    /// Presence indicates an in-progress (or crashed) recording.
    public static let markerFileName = ".recording"

    // MARK: - Init

    /// Creates a `RecordingController`.
    ///
    /// - Parameters:
    ///   - store: The `DataStore` actor for creating meetings and attaching audio.
    ///   - permissions: The `Permissions` instance for mic authorization.
    ///   - storageRoot: Root directory for recordings (e.g. `.../Application Support/Biscotti/Recordings`).
    ///   - makeRecorder: Factory that creates a fresh single-use `RecorderControlling` per session.
    ///   - denialCheckDelay: How long to wait before checking system-audio denial (default 2 s; inject a
    ///     shorter value in tests).
    public init(
        store: DataStore,
        permissions: Permissions,
        storageRoot: URL,
        makeRecorder: @escaping @Sendable () -> any RecorderControlling,
        denialCheckDelay: Duration = .seconds(2)
    ) {
        self.store = store
        self.permissions = permissions
        self.storageRoot = storageRoot
        self.makeRecorder = makeRecorder
        self.denialCheckDelay = denialCheckDelay
    }

    // MARK: - Notes

    /// Adds a timestamped note to the current session.
    ///
    /// Empty or whitespace-only text is ignored. The timestamp is the
    /// current `state.elapsed` at the moment of the call.
    public func addNote(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let note = MeetingNote(text: trimmed, timestamp: state.elapsed)
        notes.append(note)
    }

    /// Updates the text of an existing note. The timestamp is preserved.
    public func updateNote(id: UUID, text: String) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[index].text = text
    }

    /// Removes a note by its stable ID.
    public func removeNote(id: UUID) {
        notes.removeAll(where: { $0.id == id })
    }

    // MARK: - Start

    /// Starts a new recording session.
    ///
    /// Flow: request mic permission (JIT) -> create meeting -> write marker ->
    /// create directory -> attach audio refs -> start engine -> pump elapsed ->
    /// schedule system-audio denial check. The real system tap surfaces the TCC
    /// prompt on first use — no pre-record probe.
    public func start() async {
        lastError = nil
        systemAudioWarning = false
        notes = []

        guard !state.isRecording else {
            lastError = .alreadyRecording
            return
        }

        // Mic permission (JIT, via Permissions seam)
        let micGranted = await permissions.requestMicrophone()
        guard micGranted else {
            lastError = .permissionDenied(.microphone)
            return
        }

        let newRecorder = makeRecorder()

        // Create meeting + directory + marker + audio refs
        guard let setup = await setupMeetingStorage() else {
            return // lastError set inside setupMeetingStorage
        }

        // Start the engine
        let paths = CapturePaths(micAAC: setup.micPath, systemAAC: setup.systemPath)
        do {
            try await newRecorder.start(paths: paths)
        } catch {
            cleanupFailedStart(meetingID: setup.meetingID)
            lastError = .engineFailed(error.localizedDescription)
            return
        }

        recorder = newRecorder
        state = RecordingState(
            isRecording: true, elapsed: 0,
            meetingID: setup.meetingID, startDate: Date()
        )
        startStateStreamPump(recorder: newRecorder)
        scheduleDenialCheck(recorder: newRecorder)
    }

    // MARK: - Stop

    /// Stops the current recording session.
    ///
    /// Returns the meeting ID of the just-stopped recording, or `nil` if not recording.
    @discardableResult
    public func stop() async -> UUID? {
        guard state.isRecording, let currentRecorder = recorder, let meetingID = state.meetingID else {
            return nil
        }

        // Stop the engine
        await currentRecorder.stop()

        // Cancel background tasks
        stateStreamTask?.cancel()
        stateStreamTask = nil
        denialCheckTask?.cancel()
        denialCheckTask = nil

        // Delete the marker file
        let meetingDir = storageRoot.appendingPathComponent(meetingID.uuidString)
        let markerURL = meetingDir.appendingPathComponent(Self.markerFileName)
        try? FileManager.default.removeItem(at: markerURL)

        // Mark audio presence/sizes in the store
        do {
            try await store.markAudioPresence(meetingID: meetingID)
        } catch {
            // Non-fatal: the files exist but the store update failed.
            // isPresent stays false and audioPaths gates on it, so the meeting
            // will appear to have no audio until a future reconciliation pass
            // (e.g. orphan recovery on next launch) succeeds.
            Self.logger.warning("markAudioPresence failed for \(meetingID): \(error.localizedDescription)")
        }

        // Persist recording duration (capture before resetting state)
        let elapsed = state.elapsed
        if elapsed > 0 {
            do {
                try await store.setRecordingDuration(elapsed, for: meetingID)
            } catch {
                Self.logger.warning("setRecordingDuration failed for \(meetingID): \(error.localizedDescription)")
            }
        }

        // Seed in-memory notes into the meeting's notes field
        if let section = NotesMarkdown.generate(notes: notes, meetingID: meetingID) {
            do {
                let detail = try await store.meetingDetail(id: meetingID)
                let existing = detail?.notes ?? ""
                let merged = NotesMarkdown.merged(existing: existing, section: section)
                try await store.setNotes(merged, for: meetingID)
            } catch {
                Self.logger.warning("Notes seeding failed for \(meetingID): \(error.localizedDescription)")
            }
        }

        // Reset state
        recorder = nil
        notes = []
        state = .idle

        return meetingID
    }

    // MARK: - Orphan Recovery

    /// Scans the storage root for `.recording` marker files left by a crash.
    ///
    /// For each orphaned recording directory: marks audio presence in the store,
    /// deletes the stale marker, and leaves the meeting as a completed-but-
    /// untranscribed recording the user can transcribe.
    public func recoverOrphans() async {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(
            at: storageRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for dirURL in contents {
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: dirURL.path, isDirectory: &isDir),
                  isDir.boolValue
            else {
                continue
            }

            let markerURL = dirURL.appendingPathComponent(Self.markerFileName)
            guard fileManager.fileExists(atPath: markerURL.path) else {
                continue
            }

            // This directory has a stale marker -- it was recording when the app crashed.
            guard let meetingID = UUID(uuidString: dirURL.lastPathComponent) else {
                continue
            }

            // Mark audio presence (updates isPresent + byteSize from disk)
            try? await store.markAudioPresence(meetingID: meetingID)

            // Delete the stale marker
            try? fileManager.removeItem(at: markerURL)
        }
    }

    // MARK: - Onboarding support

    /// Probes for system-audio permission and infers the state.
    ///
    /// Triggers the macOS system-audio prompt (if not already decided)
    /// by exercising the capture engine briefly, then checks the
    /// `probableSystemAudioDenied` heuristic to update `Permissions`.
    public func probeSystemAudioAndInferState() async {
        let probeRecorder = makeRecorder()
        await probeSystemAudioPermission(recorder: probeRecorder)

        // Brief delay for the system to settle the TCC state
        try? await Task.sleep(for: .milliseconds(500))

        let denied = await probeRecorder.probableSystemAudioDenied()
        if denied {
            permissions.noteSystemAudio(.denied)
        } else {
            permissions.noteSystemAudio(.authorized)
        }
    }

    // MARK: - Private types

    /// Captures the artefacts created by `setupMeetingStorage()`.
    private struct MeetingSetup {
        let meetingID: UUID
        let micPath: URL
        let systemPath: URL
    }

    // MARK: - Private helpers

    /// Generates an auto-title for a new recording.
    ///
    /// The title is just "Untitled Meeting" -- the date is already stored as
    /// `Meeting.startDate` / `Meeting.createdAt` and displayed separately
    /// in the UI, so embedding it in the title would cause duplication.
    /// Calendar association will replace this with the event title unless
    /// the user has manually edited the title.
    public static func autoTitle() -> String {
        "Untitled Meeting"
    }

    /// Triggers the system-audio TCC prompt by briefly exercising the engine.
    ///
    /// System audio has no public permission API; the only way to surface the
    /// macOS prompt is to create a Core Audio process tap via the engine's
    /// `requestPermissions(systemProbePath:)`. Uses a scratch file under the
    /// storage root that is safe to discard.
    private func probeSystemAudioPermission(recorder: any RecorderControlling) async {
        let probePath = storageRoot.appendingPathComponent(".system_probe.aac")
        _ = await recorder.requestPermissions(systemProbePath: probePath)
        try? FileManager.default.removeItem(at: probePath)
    }

    /// Creates the meeting, recording directory, marker file, and audio refs.
    ///
    /// Returns the meeting setup on success, or `nil` on failure (with
    /// `lastError` already set). Eagerly cleans up partial state on failure
    /// so the meeting doesn't become an invisible orphan.
    private func setupMeetingStorage() async -> MeetingSetup? {
        let title = Self.autoTitle()
        let meetingID: UUID
        do {
            meetingID = try await store.createMeeting(title: title)
        } catch {
            lastError = .storageFailed("Failed to create meeting: \(error.localizedDescription)")
            return nil
        }

        let meetingDir = storageRoot.appendingPathComponent(meetingID.uuidString)
        let micPath = meetingDir.appendingPathComponent("mic.aac")
        let systemPath = meetingDir.appendingPathComponent("system.aac")

        // Create recording directory + marker. The marker is written as early as
        // possible after meeting creation so `recoverOrphans` can find and reconcile
        // the meeting if the app crashes during the remaining setup steps.
        do {
            try FileManager.default.createDirectory(at: meetingDir, withIntermediateDirectories: true)
            let markerURL = meetingDir.appendingPathComponent(Self.markerFileName)
            FileManager.default.createFile(atPath: markerURL.path, contents: nil)
        } catch {
            try? await store.delete(meetingID: meetingID)
            lastError = .storageFailed("Failed to create recording directory: \(error.localizedDescription)")
            return nil
        }

        // Attach audio refs BEFORE starting the engine (crash-safety).
        let micRef = AudioFileRef(role: .mic, path: micPath.path, byteSize: 0, isPresent: false)
        let sysRef = AudioFileRef(role: .system, path: systemPath.path, byteSize: 0, isPresent: false)
        do {
            try await store.attachAudio([micRef, sysRef], to: meetingID)
        } catch {
            cleanupFailedStart(meetingID: meetingID)
            lastError = .storageFailed("Failed to attach audio refs: \(error.localizedDescription)")
            return nil
        }

        return MeetingSetup(meetingID: meetingID, micPath: micPath, systemPath: systemPath)
    }

    /// Removes the marker, directory, and meeting for a session that failed
    /// partway through `start()`. Best-effort -- if cleanup itself fails, the
    /// meeting + marker remain and `recoverOrphans` will reconcile on next launch.
    private func cleanupFailedStart(meetingID: UUID) {
        let meetingDir = storageRoot.appendingPathComponent(meetingID.uuidString)
        try? FileManager.default.removeItem(at: meetingDir)
        let capturedStore = store
        cleanupTask = Task { try? await capturedStore.delete(meetingID: meetingID) }
    }

    /// Waits for any pending cleanup from a failed `start()` to finish.
    ///
    /// Exposed at package visibility so tests can deterministically observe
    /// cleanup completion instead of relying on fixed sleep durations.
    package func awaitPendingCleanup() async {
        await cleanupTask?.value
        cleanupTask = nil
    }

    /// Pumps the engine's `stateStream()` into our observable `state.elapsed`.
    private func startStateStreamPump(recorder: any RecorderControlling) {
        stateStreamTask = Task { [weak self] in
            let stream = recorder.stateStream()
            for await captureState in stream {
                guard !Task.isCancelled else { break }
                guard let self else { break }
                state.elapsed = captureState.elapsed
            }
        }
    }

    /// After a delay, checks if the engine thinks system audio is denied.
    ///
    /// Sets the in-memory `systemAudioWarning` flag only — does **not** write
    /// any durable/persisted permission state. The all-zero detection infra is
    /// retained for potential Stage 3 reuse (in-recording hint).
    private func scheduleDenialCheck(recorder: any RecorderControlling) {
        // TODO: Stage 3 — the all-zero detection infra here may power the in-recording hint
        let delay = denialCheckDelay
        denialCheckTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            let denied = await recorder.probableSystemAudioDenied()
            guard let self else { return }
            if denied {
                systemAudioWarning = true
            }
        }
    }
}
