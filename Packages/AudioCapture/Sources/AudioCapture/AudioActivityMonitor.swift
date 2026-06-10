import CoreAudio
import Foundation
import os

private let logger = Logger(subsystem: "net.scosman.biscotti.audiocapture", category: "AudioActivityMonitor")

/// Monitors audio process activity and emits snapshots via `AsyncStream`.
///
/// Each call to `activityStream()` returns an independent stream that
/// receives `[AudioProcess]` snapshots whenever the set of audio-using
/// processes or their running state changes. The initial snapshot is
/// emitted immediately on subscription.
///
/// Built on a `ProcessActivitySource` seam so the monitoring logic can
/// be tested with synthetic inputs (no live Core Audio required).
public actor AudioActivityMonitor {
    // MARK: - Dependencies

    private let source: any ProcessActivitySource

    // MARK: - State

    private var continuations: [UUID: AsyncStream<[AudioProcess]>.Continuation] = [:]
    private var monitoringTask: Task<Void, Never>?
    private var lastSnapshot: [AudioProcess] = []

    // MARK: - Init

    /// Creates a monitor with an injected activity source.
    ///
    /// For production use, prefer `AudioActivityMonitor.live()` which
    /// wires the real Core Audio implementation.
    public init(source: some ProcessActivitySource) {
        self.source = source
    }

    // MARK: - Public API

    /// Returns an async stream of `[AudioProcess]` snapshots.
    ///
    /// The stream emits the current snapshot immediately, then emits
    /// updated snapshots whenever the process list or running state
    /// changes. Multiple consumers can call this; each gets its own stream.
    public func activityStream() -> AsyncStream<[AudioProcess]> {
        let id = UUID()
        return AsyncStream { continuation in
            self.continuations[id] = continuation

            // Emit current snapshot immediately.
            let snapshot = self.source.currentProcesses()
            self.lastSnapshot = snapshot
            continuation.yield(snapshot)

            // Start monitoring if this is the first consumer.
            if self.monitoringTask == nil {
                self.startMonitoring()
            }

            continuation.onTermination = { @Sendable [weak self] _ in
                Task { [weak self] in
                    await self?.removeContinuation(id: id)
                }
            }
        }
    }

    // MARK: - Internal

    private func startMonitoring() {
        let source = source
        monitoringTask = Task { [weak self] in
            let changes = source.processChanges()
            for await _ in changes {
                guard !Task.isCancelled else { break }
                await self?.handleChange()
            }
            // Stream ended — finish all continuations.
            await self?.finishAll()
        }
    }

    private func handleChange() {
        let snapshot = source.currentProcesses()
        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        for (_, continuation) in continuations {
            continuation.yield(snapshot)
        }
    }

    private func removeContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
        if continuations.isEmpty {
            monitoringTask?.cancel()
            monitoringTask = nil
        }
    }

    private func finishAll() {
        for (_, continuation) in continuations {
            continuation.finish()
        }
        continuations.removeAll()
        monitoringTask = nil
    }
}

// MARK: - Live factory

public extension AudioActivityMonitor {
    /// Creates a monitor wired to real Core Audio property listeners.
    ///
    /// Use this for production; use the main `init` with fakes for tests.
    static func live() -> AudioActivityMonitor {
        AudioActivityMonitor(source: LiveProcessActivitySource())
    }
}
