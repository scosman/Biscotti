import DataStore
import Foundation
import os

/// Outcome of importing one or more audio files.
public struct AudioImportResult: Sendable, Equatable {
    /// IDs of the meetings that were created, in the order chosen.
    public let imported: [UUID]
    /// Files that were skipped, with a user-facing reason.
    public let failures: [Failure]

    public struct Failure: Sendable, Equatable {
        public let fileName: String
        public let message: String
    }
}

// MARK: - Audio import

/// Importing an uploaded audio file creates an ordinary `Meeting` and then runs
/// the *same* pipeline a finished live recording gets: transcribe, then
/// summarize / title / name speakers.
///
/// ```text
/// importAudio(urls)
///   for each file:
///     inspect          -> duration + the file's own date (rejects non-audio)
///     create Meeting   -> dated with the file's date, "Untitled Meeting"
///     copy file        -> <recordings>/<meetingID>/imported.<ext>
///     attach ref       -> AudioFileRef(role: .imported)
///   select first meeting
///   queue background job (one at a time): transcribe -> runAutoEnhancements
/// ```
public extension AppCore {
    /// Imports the given audio files as new meetings.
    ///
    /// Does nothing while a live recording is active (one pipeline at a time).
    /// Files that fail validation or copying are reported in `failures`; the
    /// rest still import.
    @discardableResult
    func importAudio(urls: [URL]) async -> AudioImportResult {
        guard runState == .idle || runState == .detectedPending else {
            return AudioImportResult(
                imported: [],
                failures: urls.map {
                    .init(fileName: $0.lastPathComponent, message: "Finish the current recording first.")
                }
            )
        }

        var imported: [UUID] = []
        var failures: [AudioImportResult.Failure] = []

        for url in urls {
            do {
                try await imported.append(importSingleAudioFile(at: url))
            } catch {
                audioImportLog.error("import failed: \(String(describing: error), privacy: .public)")
                failures.append(.init(fileName: url.lastPathComponent, message: error.localizedDescription))
            }
        }

        guard let first = imported.first else {
            return AudioImportResult(imported: [], failures: failures)
        }

        await reloadSummaries()
        select(first)
        for meetingID in imported {
            enqueueTranscription(meetingID: meetingID)
        }
        return AudioImportResult(imported: imported, failures: failures)
    }
}

// MARK: - Private

private extension AppCore {
    /// Validates, creates the meeting, and copies the audio in. Rolls back
    /// (meeting row + folder) if anything after meeting creation fails.
    func importSingleAudioFile(at url: URL) async throws -> UUID {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let info = try await audioInspector.inspect(url: url)

        let meetingID = try await store.createMeeting(
            title: Meeting.defaultTitle,
            start: info.date,
            end: info.date.addingTimeInterval(info.duration)
        )
        let meetingDir = recording.storageRoot.appendingPathComponent(meetingID.uuidString)

        do {
            try FileManager.default.createDirectory(at: meetingDir, withIntermediateDirectories: true)
            let ext = url.pathExtension.lowercased()
            let destination = meetingDir.appendingPathComponent("imported.\(ext)")
            try FileManager.default.copyItem(at: url, to: destination)

            try await store.attachAudio(
                [AudioFileRef(role: .imported, path: destination.path, byteSize: 0, isPresent: false)],
                to: meetingID
            )
            try await store.markAudioPresence(meetingID: meetingID)
            try await store.setRecordingDuration(info.duration, for: meetingID)
        } catch {
            try? FileManager.default.removeItem(at: meetingDir)
            try? await store.delete(meetingID: meetingID)
            throw AudioImportError.copyFailed(error.localizedDescription)
        }
        return meetingID
    }

    /// Queues transcription + enhancement behind any job already running, so
    /// several imported files are processed one after another (the
    /// transcription service allows one job at a time).
    func enqueueTranscription(meetingID: UUID) {
        let previous = pendingTranscriptionTask
        pendingTranscriptionTask = Task { @MainActor [transcription, intelligence] in
            await previous?.value
            await transcription.transcribe(meetingID: meetingID)
            await intelligence.runAutoEnhancements(meetingID: meetingID)
        }
    }
}

private let audioImportLog = Logger(subsystem: "net.scosman.biscotti", category: "AudioImport")
