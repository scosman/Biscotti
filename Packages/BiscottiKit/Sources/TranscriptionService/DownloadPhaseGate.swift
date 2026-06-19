import Foundation

/// Delays surfacing of download-phase status messages so cache-hit model
/// loads (which finish quickly) never flash a "Downloading..." subtitle.
///
/// The gate absorbs status callbacks for a configurable delay. If the
/// download phase completes before the delay elapses, `cancel()` prevents
/// the callback from ever firing. If the delay expires while the download
/// is still in progress, the gate fires the most recently registered
/// callback (latest-message-wins) and marks itself as elapsed so
/// subsequent messages pass through immediately.
///
/// Designed for `@MainActor` use inside `TranscriptionService`.
@MainActor
final class DownloadPhaseGate {
    private let delay: Duration
    private var delayTask: Task<Void, Never>?

    /// The most recently registered callback. Updated on each `start`
    /// call so that the delay fires with the latest message.
    private var pendingCallback: (@MainActor () -> Void)?

    /// Whether the delay has elapsed and messages should pass through.
    private(set) var hasElapsed = false

    init(delay: Duration) {
        self.delay = delay
    }

    /// Registers a callback and starts the delay timer (if not already
    /// running). When the delay expires, invokes the **most recently
    /// registered** callback (latest-message-wins) and marks the gate
    /// as elapsed.
    ///
    /// Multiple calls before the delay elapses update the pending
    /// callback but do not restart the timer.
    ///
    /// - Parameter onElapsed: Callback invoked on the MainActor when the
    ///   delay expires. Typically sets the `.downloadingModel` job status
    ///   with the latest engine message.
    func start(_ onElapsed: @escaping @MainActor () -> Void) {
        guard !hasElapsed else { return }

        // Always update the pending callback to the latest message.
        pendingCallback = onElapsed

        // Only start the timer once; subsequent calls just update the
        // pending callback above.
        guard delayTask == nil else { return }
        let capturedDelay = delay
        delayTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: capturedDelay)
            } catch {
                return // cancelled
            }
            guard let self, !Task.isCancelled else { return }
            hasElapsed = true
            pendingCallback?()
            pendingCallback = nil
        }
    }

    /// Cancels the pending delay timer, preventing the download subtitle
    /// from appearing. Called when the download phase finishes before the
    /// delay elapses (cache hit).
    func cancel() {
        delayTask?.cancel()
        delayTask = nil
        pendingCallback = nil
    }
}
