import AudioCapture
import CoreAudio
import Foundation
import MeetingCatalog
import MeetingDetection

// MARK: - ImmediateClock

/// A clock that completes `sleep` immediately, making debounce
/// timers fire without real delays.
struct ImmediateClock: Clock {
    typealias Duration = Swift.Duration

    struct Instant: InstantProtocol {
        var offset: Swift.Duration
        static var zero: Instant {
            Instant(offset: .zero)
        }

        func advanced(by duration: Swift.Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        func duration(to other: Instant) -> Swift.Duration {
            other.offset - offset
        }

        static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    var now: Instant {
        .zero
    }

    var minimumResolution: Swift.Duration {
        .zero
    }

    func sleep(
        until _: Instant, tolerance _: Swift.Duration?
    ) async throws {
        try Task.checkCancellation()
        await Task.yield()
    }
}

// MARK: - OneShotImmediateClock

/// A clock that completes the first `sleep` immediately, then
/// suspends forever on subsequent calls (until cancelled). This
/// allows the start debounce to fire while keeping the stop
/// debounce pending so that cancellation behavior can be tested
/// deterministically.
final class OneShotImmediateClock: Clock, @unchecked Sendable {
    typealias Duration = Swift.Duration

    struct Instant: InstantProtocol {
        var offset: Swift.Duration
        static var zero: Instant {
            Instant(offset: .zero)
        }

        func advanced(by duration: Swift.Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        func duration(to other: Instant) -> Swift.Duration {
            other.offset - offset
        }

        static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    private let lock = NSLock()
    private var fired = false

    var now: Instant {
        .zero
    }

    var minimumResolution: Swift.Duration {
        .zero
    }

    func sleep(
        until _: Instant, tolerance _: Swift.Duration?
    ) async throws {
        let shouldFireImmediately: Bool = lock.withLock {
            if !fired {
                fired = true
                return true
            }
            return false
        }

        if shouldFireImmediately {
            try Task.checkCancellation()
            await Task.yield()
        } else {
            // Block until cancelled, same as NeverClock.
            let box = ContinuationBox()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    box.store(cont)
                    if Task.isCancelled {
                        box.resume(throwing: CancellationError())
                    }
                }
            } onCancel: {
                box.resume(throwing: CancellationError())
            }
        }
    }
}

// MARK: - ContinuationBox

/// Thread-safe box for sharing a `CheckedContinuation` between the
/// `withCheckedThrowingContinuation` body and the `onCancel` handler.
private final class ContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var resumed = false

    func store(_ cont: CheckedContinuation<Void, Error>) {
        lock.lock()
        continuation = cont
        lock.unlock()
    }

    func resume(throwing error: Error) {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed, let cont = continuation else { return }
        resumed = true
        cont.resume(throwing: error)
    }
}

// MARK: - NeverClock

/// A clock whose `sleep` never returns (until cancelled).
struct NeverClock: Clock {
    typealias Duration = Swift.Duration

    struct Instant: InstantProtocol {
        var offset: Swift.Duration
        static var zero: Instant {
            Instant(offset: .zero)
        }

        func advanced(by duration: Swift.Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        func duration(to other: Instant) -> Swift.Duration {
            other.offset - offset
        }

        static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    var now: Instant {
        .zero
    }

    var minimumResolution: Swift.Duration {
        .zero
    }

    func sleep(
        until _: Instant, tolerance _: Swift.Duration?
    ) async throws {
        // Suspend without polling until the task is cancelled.
        let box = ContinuationBox()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                box.store(cont)
                // If already cancelled before we stored, resume now.
                if Task.isCancelled {
                    box.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            box.resume(throwing: CancellationError())
        }
    }
}

// MARK: - FakeActivitySource

/// Fake `ActivitySource` that yields scripted snapshots on demand.
final class FakeActivitySource: ActivitySource, @unchecked Sendable {
    let continuation: AsyncStream<[AudioProcess]>.Continuation
    let stream: AsyncStream<[AudioProcess]>

    init() {
        var cont: AsyncStream<[AudioProcess]>.Continuation!
        stream = AsyncStream(bufferingPolicy: .unbounded) { cont = $0 }
        continuation = cont
    }

    func activityStream() -> AsyncStream<[AudioProcess]> {
        stream
    }

    func emit(_ snapshot: [AudioProcess]) {
        continuation.yield(snapshot)
    }

    func finish() {
        continuation.finish()
    }
}

// MARK: - FakeMeetingCatalog

/// Fake `MeetingCatalog` with controlled responses.
struct FakeMeetingCatalog: MeetingCatalog {
    var meetingBundleIDs: Set<String> = []
    var parentMapping: [String: String] = [:]
    var displayNames: [String: String] = [:]

    func displayName(forBundleID bundleID: String) -> String? {
        if let parentID = parentMapping[bundleID] {
            return displayNames[parentID]
        }
        return displayNames[bundleID]
    }

    func isMeetingApp(bundleID: String) -> Bool {
        meetingBundleIDs.contains(bundleID)
    }

    func parentBundleID(forHelperBundleID bundleID: String) -> String? {
        parentMapping[bundleID]
    }

    func conferenceMatch(
        inURL _: URL?, location _: String?, notes _: String?
    ) -> (platform: String, url: URL)? {
        nil
    }
}

// MARK: - AudioProcess factory

/// Convenience factory for `AudioProcess` test stubs.
func makeProcess(
    bundleID: String?,
    isRunningInput: Bool = false,
    isRunningOutput: Bool = false,
    pid: pid_t = 1
) -> AudioProcess {
    AudioProcess(
        id: AudioObjectID(pid),
        bundleID: bundleID,
        pid: pid,
        isRunningInput: isRunningInput,
        isRunningOutput: isRunningOutput
    )
}

// MARK: - EventCollector

/// Collects detection events from a background task without blocking
/// the MainActor with `for await`.
@MainActor
final class EventCollector {
    private(set) var events: [DetectionEvent] = []
    private var task: Task<Void, Never>?

    func start(from detector: MeetingDetector) {
        let stream = detector.events()
        task = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { break }
                self?.events.append(event)
            }
        }
    }

    /// Waits until the collector has at least `count` events or gives up.
    /// Uses an iteration count instead of a wall-clock deadline so that
    /// MainActor starvation under parallel test execution cannot trip
    /// the bound prematurely.
    func waitForEvents(
        count: Int,
        maxIterations: Int = 500
    ) async {
        var iteration = 0
        while events.count < count, iteration < maxIterations {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
            iteration += 1
        }
    }

    /// Waits briefly for any additional events to settle.
    func settle() async {
        try? await Task.sleep(for: .milliseconds(50))
        await Task.yield()
    }

    func cancel() {
        task?.cancel()
    }
}

// MARK: - Shared detector factory

@MainActor
func makeImmediateDetector(
    catalog: FakeMeetingCatalog,
    source: FakeActivitySource
) -> MeetingDetector {
    MeetingDetector(
        catalog: catalog,
        source: source,
        clock: AnyClock(ImmediateClock())
    )
}

@MainActor
func makeNeverDetector(
    catalog: FakeMeetingCatalog,
    source: FakeActivitySource
) -> MeetingDetector {
    MeetingDetector(
        catalog: catalog,
        source: source,
        clock: AnyClock(NeverClock())
    )
}

/// Creates a detector whose first debounce (start) fires immediately
/// but whose second debounce (stop) blocks until cancelled. This
/// makes stop-debounce cancellation tests deterministic.
@MainActor
func makeOneShotDetector(
    catalog: FakeMeetingCatalog,
    source: FakeActivitySource
) -> MeetingDetector {
    MeetingDetector(
        catalog: catalog,
        source: source,
        clock: AnyClock(OneShotImmediateClock())
    )
}
