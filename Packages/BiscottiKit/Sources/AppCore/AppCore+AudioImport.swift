import DataStore
import Foundation
import os
import Recording

private let audioImportLog = Logger(
    subsystem: "net.scosman.biscotti",
    category: "AudioImport"
)

// MARK: - Transcribe an existing audio file

public extension AppCore {
    /// Imports an audio file from disk as a new meeting and queues
    /// transcription + auto-enhancements, like a just-stopped recording.
    ///
    /// The file is validated first (nothing is created for a bad file). The
    /// meeting is titled after the file, dated by the file's creation date,
    /// and never associated with a calendar event. The file is copied to
    /// `<Recordings>/<meetingUUID>/imported.<ext>` and attached as a single
    /// `.mic` audio ref. Any failure after the meeting row exists removes
    /// both the row and the directory. Does not touch `runState`, so it is
    /// safe while a recording is active.
    ///
    /// - Returns: the new meeting's ID, or a user-presentable error.
    func importAudioFile(
        at url: URL,
        importer: AudioFileImporter = AudioFileImporter()
    ) async -> Result<UUID, AudioImportError> {
        // 1. Validate off the main actor, before creating anything.
        let validated: ValidatedAudio
        do {
            validated = try await Task.detached(priority: .userInitiated) {
                try await importer.validate(url)
            }.value
        } catch let error as AudioImportError {
            return .failure(error)
        } catch {
            return .failure(.unreadable)
        }

        // 2. Create the meeting (no calendar association).
        let fileTitle = url.deletingPathExtension().lastPathComponent
        let title = fileTitle.isEmpty ? Meeting.defaultTitle : fileTitle
        let meetingID: UUID
        do {
            meetingID = try await store.createMeeting(title: title, start: validated.startDate)
        } catch {
            return .failure(.storageFailed(error.localizedDescription))
        }

        // 3-4. Stage the file, attach the ref, record the duration.
        let directory = recording.meetingDirectory(for: meetingID)
        do {
            try await stageImportedAudio(
                source: url, validated: validated, meetingID: meetingID,
                directory: directory, importer: importer
            )
        } catch {
            await Task.detached { importer.discard(directory: directory) }.value
            try? await store.delete(meetingID: meetingID)
            audioImportLog.error(
                "import failed, rolled back \(meetingID): \(String(describing: error), privacy: .public)"
            )
            return .failure(error)
        }

        // 5. Surface it and kick off transcription like stopRecording().
        await reloadSummaries()
        if recording.state.isRecording {
            // Don't pull the user off the live recording screen.
            selectFromList([meetingID])
        } else {
            select(meetingID)
        }
        spawnTranscription(meetingID: meetingID)
        return .success(meetingID)
    }
}

// MARK: - Batch entry point (menu, toolbar, popover, drop)

public extension AppCore {
    /// The single funnel for every "import audio" entry point. Imports the
    /// files one at a time, in order; files that are not audio/video are
    /// reported without touching the importer. Failures are collected into
    /// `audioImportFailures` (one alert for the whole batch).
    ///
    /// Re-entrant: a call made while a batch is running queues its URLs onto
    /// that batch and returns immediately.
    ///
    /// Files are validated and copied one after another, while their
    /// transcriptions wait their turn in the shared transcription queue (a
    /// meeting shows "Queued" until then), so every file transcribes even
    /// when another transcription is already running.
    func importAudioFiles(at urls: [URL]) async {
        pendingAudioImports.append(contentsOf: urls)
        guard !isImportingAudio else { return }
        isImportingAudio = true
        audioImportFailures = []
        defer { isImportingAudio = false }

        var failures: [AudioImportFailure] = []
        while !pendingAudioImports.isEmpty {
            let url = pendingAudioImports.removeFirst()

            guard AudioImportSupport.isSupported(url) else {
                failures.append(AudioImportFailure(
                    fileName: url.lastPathComponent,
                    message: AudioImportSupport.unsupportedMessage
                ))
                continue
            }
            if case let .failure(error) = await importAudioFile(at: url) {
                failures.append(AudioImportFailure(
                    fileName: url.lastPathComponent,
                    message: error.localizedDescription
                ))
            }
        }
        audioImportFailures = failures
    }

    /// Dismisses the "Couldn't import" alert.
    func dismissAudioImportFailures() {
        audioImportFailures = []
    }
}

private extension AppCore {
    /// Copies the file into the meeting directory, attaches the single `.mic`
    /// ref, records the duration and clears the `.recording` marker. The
    /// caller rolls back the row and directory on any thrown error.
    func stageImportedAudio(
        source: URL,
        validated: ValidatedAudio,
        meetingID: UUID,
        directory: URL,
        importer: AudioFileImporter
    ) async throws(AudioImportError) {
        let staged: StagedAudio
        do {
            staged = try await Task.detached(priority: .userInitiated) {
                try importer.stage(source: source, into: directory)
            }.value
        } catch let error as AudioImportError {
            throw error
        } catch {
            throw .copyFailed(error.localizedDescription)
        }
        let ref = AudioFileRef(
            role: .mic, path: staged.url.path, byteSize: staged.byteSize, isPresent: true
        )
        do {
            try await store.attachAudio([ref], to: meetingID)
            try await store.setRecordingDuration(validated.duration, for: meetingID)
        } catch {
            throw .storageFailed(error.localizedDescription)
        }
        await Task.detached { importer.finalize(directory: directory) }.value
    }
}
