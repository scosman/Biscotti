import AudioToolbox
@preconcurrency import AVFoundation
import Foundation
import os
import Synchronization

private let logger = Logger(subsystem: "net.scosman.biscotti.audiocapture", category: "LiveMicCapture")

/// Owns one recording attempt's file, writes on a dedicated non-real-time
/// thread, and channels tap callbacks through a lock-free ring buffer.
///
/// The tap callback extracts channel 0 and enqueues the raw mono PCM into
/// the ring; it never encodes, writes to disk, or holds a lock for longer
/// than the memcpy. The writer thread dequeues, converts (resamples), fills
/// gaps, writes ADTS AAC, and fires the first-buffer anchor.
///
/// Each installed tap carries an identity checked under `tapLock`.
/// Invalidating a tap waits for any in-flight enqueue; subsequent callbacks
/// are dropped. `close()` drains the ring buffer before disposing the file.
/// The owner must call `close()` before releasing; the writer thread holds
/// `self` alive while running, so `deinit` cannot fire as a safety net.
final class MicCaptureSession: @unchecked Sendable { // swiftlint:disable:this type_body_length
    private final class Tap: Sendable {}

    private let processingFormat: AVAudioFormat
    private let onFirstBuffer: (@Sendable (Double) -> Void)?

    // -- Tap ownership (tapLock) --
    private let tapLock = OSAllocatedUnfairLock()
    private var activeTap: Tap?

    /// Lifecycle reads must not contend with the audio callback for tapLock.
    private let deliveredBuffer = Atomic<Bool>(false)

    /// -- Pre-allocated ring buffer (SPSC: producer = tap callback,
    ///    consumer = writer thread). All slot memory is allocated in init
    ///    so the tap callback never allocates. --
    private static let ringCapacity = 256
    /// Maximum frames per ring slot. Sized for 2× the largest
    /// realistic VPIO tap buffer: 96 kHz × 200 ms = 19,200 frames.
    /// VPIO voice processing caps at 48 kHz; 96 kHz is a generous
    /// ceiling. Total ring allocation: 256 × 19,200 × 4 ≈ 18.75 MB.
    private static let slotMaxFrames: AVAudioFrameCount = 19200
    private let slotByteSize: Int
    private let slotData: UnsafeMutableRawPointer
    private struct SlotHeader {
        var frameCount: AVAudioFrameCount = 0
        var sampleRate: Double = 0
        var hostTimeNanos: UInt64 = 0
        var occupied: Bool = false
    }

    private let slotHeaders: UnsafeMutablePointer<SlotHeader>
    private let ringHead = Atomic<Int>(0)
    private let ringTail = Atomic<Int>(0)
    private let droppedBufferCount = Atomic<Int>(0)

    // -- Writer thread --
    private var writerThread: Thread?
    private let writerRunning = Atomic<Int>(0)
    private let writerDone = DispatchSemaphore(value: 0)

    // -- Flush barrier (for test synchronization) --
    private let flushBarrier = Atomic<Bool>(false)
    private let flushDone = DispatchSemaphore(value: 0)

    // -- Writer-thread-only state (no synchronization needed) --
    private var file: ExtAudioFileRef?
    private var converter: AVAudioConverter?
    private var converterSourceFormat: AVAudioFormat?

    /// Host-clock nanoseconds when the next sample is expected: last
    /// written buffer's host time + its duration. Zero until the first
    /// buffer is written.
    private var expectedNextHostNanos: UInt64 = 0

    /// Pre-allocated silence buffer reused across gap fills, sized at
    /// `gapFillChunkFrames`. Created lazily on the first gap fill (one
    /// allocation); subsequent fills reuse the same buffer.
    private var silenceBuffer: AVAudioPCMBuffer?

    private var didNotifyFirstBuffer = false

    /// Lazily (re)created buffer for wrapping ring-slot data on the writer
    /// thread. Rebuilt when the source sample rate changes.
    private var writerInputBuffer: AVAudioPCMBuffer?
    private var writerInputRate: Double = 0

    /// Chunk size for gap-fill silence writes (frames per write call).
    private static let gapFillChunkFrames: AVAudioFrameCount = 8192

    /// Opens a new file, starts the writer thread, and captures this
    /// attempt's callback immutably. A later recorder retry cannot redirect
    /// an old tap to its own file or callback.
    init(url: URL, encoder: EncoderSettings, onFirstBuffer: (@Sendable (Double) -> Void)?) throws {
        processingFormat = encoder.processingFormat
        self.onFirstBuffer = onFirstBuffer

        slotByteSize = Int(Self.slotMaxFrames) * MemoryLayout<Float>.size
        slotData = .allocate(
            byteCount: Self.ringCapacity * slotByteSize,
            alignment: MemoryLayout<Float>.alignment
        )
        slotHeaders = .allocate(capacity: Self.ringCapacity)
        for idx in 0 ..< Self.ringCapacity {
            slotHeaders[idx] = SlotHeader()
        }

        file = try VPIOFileHelper.createExtAudioFile(
            url: url, encoder: encoder, processingFormat: processingFormat
        )

        startWriterThread()
    }

    /// Whether the currently installed tap has received nonempty hardware audio.
    /// This signals hardware liveness (a buffer arrived from the tap), not that a
    /// buffer was successfully converted and written. MicEngine uses it to choose
    /// between a lightweight same-engine restart (pre-delivery) and a full rebuild
    /// (post-delivery) on configuration changes. `onFirstBuffer` is the separate
    /// signal that confirms startup to AudioRecorder.
    /// Replacing the tap resets this without resetting the session's first anchor.
    var hasDeliveredBuffer: Bool {
        deliveredBuffer.load(ordering: .acquiring)
    }

    /// Creates the callback installed on AVAudioEngine and retires the previous
    /// tap, including during a restart of the same engine. The file stays open.
    func makeTapHandler() -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        let tap = Tap()
        tapLock.lock()
        activeTap = tap
        deliveredBuffer.store(false, ordering: .releasing)
        // Keep expectedNextHostNanos across tap replacements so gap
        // detection spans reconnects within the same session/file.
        tapLock.unlock()
        return { [self, tap] buffer, when in
            handleTap(buffer: buffer, when: when, tap: tap)
        }
    }

    /// Revokes the current tap before hardware teardown. Holding tapLock
    /// closes the check/enqueue race even if a callback is already executing.
    func invalidateTap() {
        tapLock.lock()
        defer { tapLock.unlock() }
        activeTap = nil
        deliveredBuffer.store(false, ordering: .releasing)
    }

    /// Revokes all taps, drains pending writes, and finalizes this attempt's
    /// file. Idempotent, and safe even when a removed tap still retains its
    /// callback and this session.
    func close() {
        tapLock.lock()
        activeTap = nil
        deliveredBuffer.store(false, ordering: .releasing)
        tapLock.unlock()

        if writerThread != nil {
            writerRunning.store(0, ordering: .releasing)
            writerDone.wait()
            writerThread = nil
        }

        if let file { ExtAudioFileDispose(file) }
        file = nil
        converter = nil
        converterSourceFormat = nil
    }

    /// Finalizes a session if startup failed before its owner could close it.
    deinit {
        close()
        slotData.deallocate()
        slotHeaders.deallocate()
    }

    /// Blocks until the writer thread has processed all entries currently
    /// in the ring buffer. Does not stop the writer. Used by tests to
    /// synchronize with the asynchronous writer before checking state
    /// that is only updated after a write (e.g. `onFirstBuffer` anchors).
    func flushWriter() {
        guard writerThread != nil else { return }
        flushBarrier.store(true, ordering: .releasing)
        flushDone.wait()
    }

    // MARK: - Tap callback (non-blocking, allocation-free)

    /// Extracts channel 0 and enqueues for the writer thread. Ownership
    /// validation and graph readiness updates are serialized with
    /// invalidation via tapLock.
    private func handleTap(buffer: AVAudioPCMBuffer, when: AVAudioTime, tap: Tap) {
        guard buffer.frameLength > 0, tapLock.lockIfAvailable() else { return }
        defer { tapLock.unlock() }
        guard activeTap === tap else { return }

        // Intentionally set before enqueue: this signals hardware liveness
        // (selects the full-rebuild path in MicEngine), not successful file
        // output. onFirstBuffer confirms startup.
        deliveredBuffer.store(true, ordering: .releasing)

        guard let srcChannels = buffer.floatChannelData,
              buffer.format.channelCount > 0
        else { return }

        let frameCount = buffer.frameLength
        guard frameCount <= Self.slotMaxFrames else {
            droppedBufferCount.wrappingAdd(1, ordering: .relaxed)
            return
        }

        // SPSC enqueue: copy channel 0 into pre-allocated ring slot.
        let head = ringHead.load(ordering: .acquiring)
        let nextHead = (head + 1) % Self.ringCapacity
        guard nextHead != ringTail.load(ordering: .acquiring) else {
            droppedBufferCount.wrappingAdd(1, ordering: .relaxed)
            return
        }

        let slotPtr = slotData.advanced(by: head * slotByteSize)
            .assumingMemoryBound(to: Float.self)
        slotPtr.update(from: srcChannels[0], count: Int(frameCount))

        let hostTimeNanos: UInt64 = when.isHostTimeValid
            ? AudioConvertHostTimeToNanos(when.hostTime) : 0

        slotHeaders[head] = SlotHeader(
            frameCount: frameCount,
            sampleRate: buffer.format.sampleRate,
            hostTimeNanos: hostTimeNanos,
            occupied: true
        )
        ringHead.store(nextHead, ordering: .releasing)
    }

    // MARK: - Writer thread

    private func startWriterThread() {
        writerRunning.store(1, ordering: .releasing)
        let thread = Thread { [weak self] in self?.writerLoop() }
        thread.name = "net.scosman.biscotti.mic-writer"
        thread.qualityOfService = .userInteractive
        writerThread = thread
        thread.start()
    }

    private func writerLoop() {
        while writerRunning.load(ordering: .acquiring) == 1 {
            var didWork = false
            while let entry = peekEntry() {
                didWork = true
                processEntry(entry)
                advanceTail()
            }
            // Log ring overflow count (once per drain cycle, not from
            // the tap callback — see hardware_debugging_workflow.md).
            let drops = droppedBufferCount.exchange(0, ordering: .acquiringAndReleasing)
            if drops > 0 {
                logger.notice("Mic ring overflow: \(drops, privacy: .public) buffer(s) dropped — writer thread may be stalled")
            }
            // After draining, signal any pending flush.
            if flushBarrier.exchange(false, ordering: .acquiringAndReleasing) {
                flushDone.signal()
            }
            if !didWork { Thread.sleep(forTimeInterval: 0.001) }
        }
        // Drain remaining entries after stop signal.
        while let entry = peekEntry() {
            processEntry(entry)
            advanceTail()
        }
        // Log any final overflow count.
        let finalDrops = droppedBufferCount.exchange(0, ordering: .acquiringAndReleasing)
        if finalDrops > 0 {
            logger.notice("Mic ring overflow (final): \(finalDrops, privacy: .public) buffer(s) dropped")
        }
        // Signal any pending flush before exiting.
        if flushBarrier.exchange(false, ordering: .acquiringAndReleasing) {
            flushDone.signal()
        }
        writerDone.signal()
    }

    private struct WriteEntry {
        let data: UnsafePointer<Float>
        let frameCount: AVAudioFrameCount
        let sampleRate: Double
        let hostTimeNanos: UInt64
    }

    /// Returns the entry at the current tail without advancing it.
    /// The caller must call `advanceTail()` after it has finished
    /// reading the slot data (e.g. after `processEntry` copies it).
    /// This preserves the SPSC contract: the producer cannot overwrite
    /// the slot until the consumer is done with it.
    private func peekEntry() -> WriteEntry? {
        let tail = ringTail.load(ordering: .acquiring)
        guard tail != ringHead.load(ordering: .acquiring) else { return nil }

        let header = slotHeaders[tail]
        guard header.occupied else { return nil }

        let slotPtr = slotData.advanced(by: tail * slotByteSize)
            .assumingMemoryBound(to: Float.self)

        return WriteEntry(
            data: UnsafePointer(slotPtr),
            frameCount: header.frameCount,
            sampleRate: header.sampleRate,
            hostTimeNanos: header.hostTimeNanos
        )
    }

    /// Advances the ring tail after the consumer has finished with the
    /// slot data. Must be called exactly once per `peekEntry()` hit.
    private func advanceTail() {
        let tail = ringTail.load(ordering: .acquiring)
        slotHeaders[tail].occupied = false
        ringTail.store((tail + 1) % Self.ringCapacity, ordering: .releasing)
    }

    /// Processes one ring buffer entry on the writer thread: converts,
    /// fills gaps, writes to file, and fires the first-buffer anchor.
    private func processEntry(_ entry: WriteEntry) {
        guard let file else { return }
        guard let mono = inputBuffer(for: entry) else { return }

        let bufferToWrite: AVAudioPCMBuffer
        if entry.sampleRate == processingFormat.sampleRate {
            bufferToWrite = mono
        } else {
            guard let converter = converterForSource(mono.format),
                  let converted = VPIOBufferHelper.convert(
                      mono, to: processingFormat, using: converter
                  )
            else { return }
            bufferToWrite = converted
        }

        // Fill any gap since the last written buffer with silence so the
        // mic track stays aligned with wall-clock time after reconnects.
        if expectedNextHostNanos > 0, entry.hostTimeNanos > 0 {
            fillGapWithSilence(
                expectedNextHostNanos: expectedNextHostNanos,
                actualHostNanos: entry.hostTimeNanos,
                file: file
            )
        }

        // Advance expected-next from the *input* ring entry (not the
        // resampled output). The converter may hold back or emit extra
        // frames between calls, so the output frame count does not match
        // the input's host-time span — using it would create false
        // positive gaps. Update before the write so silence is not
        // re-inserted if the write fails on the next call.
        if entry.hostTimeNanos > 0 {
            let durationNanos = UInt64(
                Double(entry.frameCount) / entry.sampleRate * 1_000_000_000
            )
            expectedNextHostNanos = entry.hostTimeNanos + durationNanos
        }

        guard VPIOBufferHelper.writeBuffer(bufferToWrite, to: file) == noErr else {
            return
        }

        guard !didNotifyFirstBuffer else { return }
        didNotifyFirstBuffer = true
        let anchor = entry.hostTimeNanos > 0
            ? Double(entry.hostTimeNanos) / 1_000_000_000
            : 0
        logger.notice("First mic buffer delivered -- anchor=\(anchor, privacy: .public)s")
        onFirstBuffer?(anchor)
    }

    /// Returns a pre-allocated mono PCM buffer populated with the ring
    /// entry's data. Lazily (re)created when the sample rate changes.
    /// Writer-thread-only.
    private func inputBuffer(for entry: WriteEntry) -> AVAudioPCMBuffer? {
        if writerInputRate != entry.sampleRate || writerInputBuffer == nil
            || (writerInputBuffer?.frameCapacity ?? 0) < entry.frameCount
        {
            guard let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: entry.sampleRate,
                channels: 1,
                interleaved: false
            ), let buf = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: max(entry.frameCount, Self.gapFillChunkFrames)
            ) else { return nil }
            writerInputBuffer = buf
            writerInputRate = entry.sampleRate
        }
        guard let buf = writerInputBuffer,
              let dst = buf.floatChannelData?[0]
        else { return nil }
        buf.frameLength = entry.frameCount
        dst.update(from: entry.data, count: Int(entry.frameCount))
        return buf
    }

    // MARK: - Gap fill (writer thread only)

    /// Writes silence for the gap between the expected and actual host
    /// times. Uses the pre-allocated silence buffer, chunking large fills
    /// to avoid unbounded allocation.
    private func fillGapWithSilence(
        expectedNextHostNanos: UInt64,
        actualHostNanos: UInt64,
        file: ExtAudioFileRef
    ) {
        var framesRemaining = gapSilenceFrameCount(
            expectedNextHostNanos: expectedNextHostNanos,
            actualHostNanos: actualHostNanos,
            sampleRate: processingFormat.sampleRate
        )
        guard framesRemaining > 0 else { return }

        let gapSeconds = Double(actualHostNanos - expectedNextHostNanos) / 1_000_000_000
        logger.notice("Mic gap fill: \(gapSeconds, privacy: .public)s (\(framesRemaining, privacy: .public) frames)")

        let chunk = Self.gapFillChunkFrames
        let buf = silenceBufferForFill()

        while framesRemaining > 0 {
            let count = AVAudioFrameCount(min(framesRemaining, Int(chunk)))
            buf.frameLength = count
            // Zero the buffer data for the active frame count.
            if let data = buf.floatChannelData?[0] {
                memset(data, 0, Int(count) * MemoryLayout<Float>.size)
            }
            if VPIOBufferHelper.writeBuffer(buf, to: file) != noErr {
                logger.error("Mic gap-fill write failed -- aborting fill")
                return
            }
            framesRemaining -= Int(count)
        }
    }

    /// Returns the pre-allocated silence buffer, creating it on first use.
    /// Writer-thread-only.
    private func silenceBufferForFill() -> AVAudioPCMBuffer {
        if let silenceBuffer { return silenceBuffer }
        guard let buf = AVAudioPCMBuffer(
            pcmFormat: processingFormat,
            frameCapacity: Self.gapFillChunkFrames
        ) else {
            preconditionFailure("Failed to allocate silence buffer for gap fill")
        }
        silenceBuffer = buf
        return buf
    }

    /// Reuses conversion state only within matching format. Rebuilds the
    /// converter when the source rate changes (e.g. after a device change).
    /// Writer-thread-only.
    private func converterForSource(_ sourceFormat: AVAudioFormat) -> AVAudioConverter? {
        if converterSourceFormat == sourceFormat, let converter { return converter }
        guard let converter = AVAudioConverter(from: sourceFormat, to: processingFormat) else {
            logger.error("Failed to build AVAudioConverter for mic resampling")
            return nil
        }
        self.converter = converter
        converterSourceFormat = sourceFormat
        return converter
    }
}
