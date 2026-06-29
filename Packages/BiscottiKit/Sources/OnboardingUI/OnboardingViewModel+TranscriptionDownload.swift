import Intelligence

// MARK: - Transcription download actions

public extension OnboardingViewModel {
    /// Start the transcription model download.
    ///
    /// Runs a click-time disk-space check first; if insufficient, sets
    /// `diskWarning` and returns without starting the download. The download
    /// runs in a retained Task so ``cancelTranscriptionDownload()`` can stop it.
    ///
    /// Guards on both `transcriptionDownloadTask` and
    /// `transcriptionCancelTask` being nil to prevent a cancel-then-restart
    /// race where the cleanup task's state reset could clobber a new download.
    func startTranscriptionDownload() {
        let downloadBytes = appCore.transcription.estimatedModelDownloadBytes
        if let warning = ModelDiskPolicy.warning(
            modelName: "Transcription & Speaker ID",
            downloadBytes: downloadBytes,
            freeBytes: availableDiskBytes()
        ) {
            diskWarning = warning
            return
        }
        guard transcriptionDownloadTask == nil,
              transcriptionCancelTask == nil
        else { return }
        transcriptionCancelled = false
        isDownloading = true
        downloadFailed = false
        downloadStatus = "Preparing\u{2026}"
        transcriptionDownloadTask = Task { [weak self] in
            await self?.runTranscriptionDownload()
            self?.transcriptionDownloadTask = nil
        }
    }

    /// Cancel the in-flight transcription model download.
    ///
    /// Kills the XPC worker (for hosted backends), deletes partial model
    /// files, and resets the row to the idle/not-downloaded state. No-op
    /// when no download is in flight.
    ///
    /// The cleanup Task is retained in `transcriptionCancelTask` so that
    /// `startTranscriptionDownload()` can guard against a cancel-then-restart
    /// race (no new download starts until cleanup finishes).
    func cancelTranscriptionDownload() {
        guard isDownloading else { return }
        transcriptionCancelled = true
        transcriptionDownloadTask?.cancel()
        transcriptionCancelTask = Task { [weak self] in
            await self?.appCore.transcription.cancelModelDownload()
            guard let self else { return }
            isDownloading = false
            downloadStatus = nil
            downloadComplete = false
            downloadFailed = false
            transcriptionCancelTask = nil
        }
    }

    /// The async body of a transcription download. Extracted from the
    /// former `startTranscriptionDownload()` so the retained Task can
    /// drive it while the cancel flag gates the outcome.
    internal func runTranscriptionDownload() async {
        do {
            try await appCore.transcription
                .ensureModelsReady { [weak self] message in
                    Task { @MainActor in
                        self?.downloadStatus = message
                    }
                }
            if !transcriptionCancelled {
                downloadComplete = true
            }
        } catch {
            if !transcriptionCancelled {
                downloadFailed = true
                downloadStatus =
                    "Download failed. You can retry or skip."
            }
        }
        if !transcriptionCancelled {
            isDownloading = false
        }
    }
}
