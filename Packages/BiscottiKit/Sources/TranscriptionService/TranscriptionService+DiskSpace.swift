import Foundation

/// Low disk space makes model loads slow: macOS deletes the compiled speech
/// models when the startup disk runs low, and the next load compiles them
/// again. The user chose (25 October 2026) to say so where the wait shows.
public extension TranscriptionService {
    /// Reads the startup disk's free space again and returns whether it is
    /// low. Settings calls it when it opens, and a slow live start when it
    /// is detected; nothing polls it. The volume query can take a while, so
    /// it runs off the main actor.
    @discardableResult
    func refreshDiskSpace() async -> Bool {
        let diskSpace = diskSpace
        let isLow = await Task.detached(priority: .utility) { diskSpace.isLow }.value
        if isLowOnDiskSpace != isLow {
            isLowOnDiskSpace = isLow
        }
        return isLow
    }
}

extension TranscriptionService {
    /// Asks the engine to report the model loads of final passes, once.
    func observeModelLoadsIfNeeded() {
        guard !observesModelLoads else { return }
        observesModelLoads = true
        let (loads, continuation) = AsyncStream.makeStream(of: Bool.self)
        let engine = engine
        Task { await engine.observeModelLoads { continuation.yield($0) } }
        // In order: a load that ends at once must not look as if it still runs.
        Task { [weak self] in
            for await isLoading in loads {
                self?.modelLoadChanged(isLoading)
            }
        }
    }

    /// A load that still runs after `slowLoadThreshold` compiled; when the
    /// disk is low too, the pass's status says so until the load ends.
    func modelLoadChanged(_ isLoading: Bool) {
        endSlowLoadCheck()
        guard isLoading, let meetingID = running else { return }
        let threshold = slowLoadThreshold
        slowLoadCheck = Task { [weak self] in
            do { try await Task.sleep(for: threshold) } catch { return }
            guard let self, running == meetingID else { return }
            let isLow = await refreshDiskSpace()
            // The load or the pass may have ended during the read.
            guard isLow, !Task.isCancelled, running == meetingID else { return }
            Self.log.notice("The final pass's model load is slow and the disk is low on space")
            slowModelLoadOnLowDisk = meetingID
        }
    }

    func endSlowLoadCheck() {
        slowLoadCheck?.cancel()
        slowLoadCheck = nil
        if slowModelLoadOnLowDisk != nil {
            slowModelLoadOnLowDisk = nil
        }
    }
}
