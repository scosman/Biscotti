import AVFoundation
import CoreAudio
import Foundation
import QuartzCore
import Synchronization
import os

private let logger = Logger(subsystem: "com.biscotti.experiments.audiolab", category: "SystemAudioCapture")

enum CaptureMode: String, CaseIterable, Identifiable, Sendable {
    case global = "Global (all system audio)"
    case perProcess = "Per-Process (target app)"

    var id: String { rawValue }
}

/// Captures system audio via Core Audio process taps.
///
/// Thread-safety contract: `start()` and `stop()` are called from the main thread.
/// The IOProc callback runs on a real-time Core Audio thread and must not block --
/// it copies buffers into a pre-allocated lock-free ring buffer (no allocation, no
/// locks). A dedicated high-priority writer thread drains the ring buffer, performs
/// RMS monitoring, and writes to disk via ExtAudioFile.
final class SystemAudioCapture: @unchecked Sendable {
    private var tapObjectID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?

    private var audioFile: ExtAudioFileRef?
    private let rmsMonitor = RMSMonitor()
    private let ringBuffer = AudioRingBuffer(capacity: 512, maxFrameCount: 8192)
    private var writerThread: Thread?
    private let writerRunning = Atomic<Int>(0)
    private let writerDone = DispatchSemaphore(value: 0)
    private let fileURL: URL
    private let captureMode: CaptureMode
    private let targetProcessID: AudioObjectID?
    private var tapSampleRate: Double = EncoderSettings.sampleRate

    /// Host-clock time (seconds, same base as `AudioConvertHostTimeToNanos`) of
    /// the mic's first delivered sample — the recording's t=0. The system tap
    /// starts slightly later and produces no frames until audio plays, so its
    /// first frame's host time minus this anchor is the exact gap we prepend as
    /// leading silence to align the two tracks. Set in `start()` before the
    /// writer thread is spawned.
    private var micAnchorSeconds: Double = 0
    /// `CACurrentMediaTime()` captured when `start()` runs. Used as a clock-
    /// agnostic upper bound on leading silence: the gap can't exceed the real
    /// wall-time the capture has been running. Guards against a bogus mic anchor
    /// (e.g. if the mic PTS clock ever differed from the tap host clock) writing
    /// a wildly over-long silence.
    private var systemStartWall: CFTimeInterval = 0
    /// Writer-thread-only: whether leading silence has been written yet.
    private var didWriteLeadingSilence = false
    /// Absolute backstop on prepended silence.
    private static let maxLeadingSilenceSeconds: Double = 3600

    private var _lock = os_unfair_lock()
    private var _isCapturing = false
    private var _writeError: OSStatus?

    var isCapturing: Bool {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        return _isCapturing
    }

    /// Non-nil if ExtAudioFileWrite failed during recording.  Checked
    /// after `stop()` to surface write errors to the UI.
    var writeError: OSStatus? {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        return _writeError
    }

    var isSuspectedFailure: Bool {
        rmsMonitor.isSuspectedFailure
    }

    init(fileURL: URL, captureMode: CaptureMode, targetProcessID: AudioObjectID? = nil) {
        self.fileURL = fileURL
        self.captureMode = captureMode
        self.targetProcessID = targetProcessID
    }

    /// - Parameter micAnchorSeconds: host-clock seconds of the mic's first
    ///   delivered sample (the recording's t=0). The system track is padded with
    ///   leading silence so its first real frame lines up with the mic. Pass 0
    ///   to disable alignment padding.
    func start(micAnchorSeconds: Double) throws {
        os_unfair_lock_lock(&_lock)
        guard !_isCapturing else {
            os_unfair_lock_unlock(&_lock)
            return
        }
        os_unfair_lock_unlock(&_lock)

        self.micAnchorSeconds = micAnchorSeconds
        systemStartWall = CACurrentMediaTime()

        do {
            try createTapAndAggregate()
            try openAudioFile()
            startWriterThread()
            try startIOProc()
        } catch {
            teardownPartialState()
            throw error
        }

        os_unfair_lock_lock(&_lock)
        _isCapturing = true
        os_unfair_lock_unlock(&_lock)
    }

    func stop() {
        os_unfair_lock_lock(&_lock)
        guard _isCapturing else {
            os_unfair_lock_unlock(&_lock)
            return
        }
        _isCapturing = false
        os_unfair_lock_unlock(&_lock)

        teardown()
    }

    // MARK: - Setup

    private func createTapAndAggregate() throws {
        let tapUUID = UUID()
        let tapDesc: CATapDescription
        if captureMode == .perProcess, let processID = targetProcessID {
            tapDesc = CATapDescription(stereoMixdownOfProcesses: [processID])
        } else {
            tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        }
        tapDesc.uuid = tapUUID
        tapDesc.name = "audiolab-system-tap"
        tapDesc.muteBehavior = .unmuted
        tapDesc.isPrivate = true

        var tapID: AudioObjectID = kAudioObjectUnknown
        var status = AudioHardwareCreateProcessTap(tapDesc, &tapID)
        guard status == noErr else {
            throw AudioLabError.failedToCreateProcessTap(status)
        }
        tapObjectID = tapID

        guard let outputDeviceID = CoreAudioHelpers.defaultOutputDeviceID(),
              let outputUID = CoreAudioHelpers.deviceUID(for: outputDeviceID)
        else {
            throw AudioLabError.couldNotQueryOutputDevice
        }

        let aggregateUID = UUID().uuidString
        let aggConfig: [String: Any] = [
            kAudioAggregateDeviceUIDKey as String: aggregateUID,
            kAudioAggregateDeviceNameKey as String: "AudioLab Aggregate",
            kAudioAggregateDeviceMainSubDeviceKey as String: outputUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [kAudioSubDeviceUIDKey as String: outputUID],
            ],
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: tapUUID.uuidString,
                    kAudioSubTapDriftCompensationKey as String: true,
                ]
            ],
        ]

        var aggID: AudioObjectID = kAudioObjectUnknown
        status = AudioHardwareCreateAggregateDevice(aggConfig as CFDictionary, &aggID)
        guard status == noErr else {
            AudioHardwareDestroyProcessTap(tapObjectID)
            tapObjectID = kAudioObjectUnknown
            throw AudioLabError.failedToCreateAggregateDevice(status)
        }
        aggregateDeviceID = aggID
    }

    private func openAudioFile() throws {
        guard let tapFormat = queryTapFormat() else {
            throw AudioLabError.couldNotQueryTapFormat
        }

        tapSampleRate = tapFormat.mSampleRate

        var outputASBD = EncoderSettings.outputASBD()
        var fileRef: ExtAudioFileRef?
        let status = ExtAudioFileCreateWithURL(
            fileURL as CFURL,
            EncoderSettings.fileType,
            &outputASBD,
            nil,
            AudioFileFlags.eraseFile.rawValue,
            &fileRef
        )
        guard status == noErr, let file = fileRef else {
            throw AudioLabError.failedToCreateAudioFile(status)
        }

        var clientFormat = tapFormat
        let clientStatus = ExtAudioFileSetProperty(
            file,
            kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
            &clientFormat
        )
        guard clientStatus == noErr else {
            ExtAudioFileDispose(file)
            throw AudioLabError.failedToSetClientFormat(clientStatus)
        }

        // Set the AAC encoder bitrate via the underlying AudioConverter.
        let brStatus = EncoderSettings.applyBitRate(to: file)
        guard brStatus == noErr else {
            ExtAudioFileDispose(file)
            throw AudioLabError.failedToSetEncoderBitRate(brStatus)
        }

        audioFile = file
    }

    private func queryTapFormat() -> AudioStreamBasicDescription? {
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(tapObjectID, &address, 0, nil, &size, &format)
        guard status == noErr else { return nil }
        return format
    }


    // MARK: - Writer Thread

    private func startWriterThread() {
        writerRunning.store(1, ordering: .releasing)
        rmsMonitor.reset()

        let thread = Thread { [weak self] in
            self?.writerLoop()
        }
        thread.name = "com.biscotti.audiolab.system-writer"
        thread.qualityOfService = .userInteractive
        writerThread = thread
        thread.start()
    }

    private func writerLoop() {
        while writerRunning.load(ordering: .acquiring) == 1 {
            var didWork = false
            while let entry = ringBuffer.dequeue() {
                didWork = true
                processEntry(entry)
            }
            if !didWork {
                // Brief yield to avoid busy-spinning when the ring buffer is empty.
                // ~1ms is short enough to keep latency low but long enough to avoid
                // burning CPU. The ring buffer has 512 slots at ~10ms per IOProc
                // callback, so ~5 seconds of runway before overflow.
                Thread.sleep(forTimeInterval: 0.001)
            }
        }

        // Drain remaining buffers after stop signal
        while let entry = ringBuffer.dequeue() {
            processEntry(entry)
        }

        // Log any dropped buffers so data loss is visible during validation
        let dropped = ringBuffer.droppedBuffers.load(ordering: .acquiring)
        if dropped > 0 {
            logger.warning("Ring buffer dropped \(dropped) buffer(s) during this recording session")
        }

        // Signal teardown that the writer has fully drained and exited
        writerDone.signal()
    }

    private func processEntry(_ entry: AudioRingBuffer.Entry) {
        // Before the first real frame, prepend leading silence so the system
        // track's first frame lines up with the mic's first frame (recording
        // t=0). Runs once, on the writer thread.
        if !didWriteLeadingSilence {
            didWriteLeadingSilence = true
            writeLeadingSilence(channelCount: entry.channelCount, firstFrameHostTime: entry.hostTime)
        }

        let frameCount = Int(entry.frameCount)
        let channelCount = Int(max(entry.channelCount, 1))
        let sampleCount = frameCount * channelCount
        let sampleRate = tapSampleRate

        // RMS monitoring -- runs on writer thread, not RT thread.
        // sampleCount covers all channels so the RMS reflects the
        // full signal regardless of channel layout.
        entry.data.withMemoryRebound(to: Float.self, capacity: sampleCount) { samples in
            let duration = Double(frameCount) / sampleRate
            rmsMonitor.processSamples(samples, count: sampleCount, bufferDuration: duration)
        }

        // Write to file -- runs on writer thread, not RT thread.
        guard let file = audioFile else { return }

        // Validate that the byte size we are about to hand to
        // ExtAudioFileWrite actually matches the frame count.
        let expectedBytes = UInt32(sampleCount) * UInt32(MemoryLayout<Float>.size)
        guard entry.dataByteSize >= expectedBytes else {
            logger.error("Buffer byte size (\(entry.dataByteSize)) < expected (\(expectedBytes)) for \(frameCount) frames x \(channelCount) ch -- skipping write")
            return
        }

        let buffer = AudioBuffer(
            mNumberChannels: entry.channelCount,
            mDataByteSize: entry.dataByteSize,
            mData: entry.data
        )
        var bufferList = AudioBufferList(mNumberBuffers: 1, mBuffers: buffer)
        let writeStatus = ExtAudioFileWrite(file, UInt32(frameCount), &bufferList)
        if writeStatus != noErr {
            logger.error("ExtAudioFileWrite failed: \(writeStatus)")

            // Record the first write error so it can be surfaced to the UI.
            os_unfair_lock_lock(&_lock)
            if _writeError == nil {
                _writeError = writeStatus
            }
            os_unfair_lock_unlock(&_lock)
        }
    }

    /// Writes `T_sys - micAnchor` worth of silent frames to the front of the
    /// file so the system track aligns with the mic track. `firstFrameHostTime`
    /// is the mach host time of the system tap's first captured frame; the gap
    /// to `micAnchorSeconds` is the precise start offset between the two streams
    /// (it covers both the deferred tap start and any idle-until-audio delay).
    /// Runs on the writer thread (allocation is fine here).
    private func writeLeadingSilence(channelCount: UInt32, firstFrameHostTime: UInt64) {
        guard firstFrameHostTime != 0, micAnchorSeconds > 0, let file = audioFile else { return }

        let sysSeconds = Double(AudioConvertHostTimeToNanos(firstFrameHostTime)) / 1_000_000_000
        let gap = sysSeconds - micAnchorSeconds
        guard gap > 0 else { return }

        // Clock-agnostic upper bound: the gap can't exceed how long the capture
        // has actually been running (plus slack for the mic->system start hop).
        // This caps a bogus anchor without trusting the host-clock comparison.
        let wallBound = max(0, CACurrentMediaTime() - systemStartWall) + 1.0
        let cappedSeconds = min(gap, wallBound, Self.maxLeadingSilenceSeconds)
        if cappedSeconds < gap {
            logger.warning("Leading-silence gap \(Int(gap))s exceeds bound; clamping to \(Int(cappedSeconds))s")
        }

        var framesRemaining = Int((cappedSeconds * tapSampleRate).rounded())
        guard framesRemaining > 0 else { return }
        logger.info("Aligning system track: prepending \(framesRemaining) frames (~\(Int(cappedSeconds * 1000))ms) of leading silence")

        let ch = Int(max(channelCount, 1))
        let chunkFrames = 8192
        var silence = [Float](repeating: 0, count: chunkFrames * ch)
        silence.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            while framesRemaining > 0 {
                let n = min(chunkFrames, framesRemaining)
                let buffer = AudioBuffer(
                    mNumberChannels: channelCount,
                    mDataByteSize: UInt32(n * ch * MemoryLayout<Float>.size),
                    mData: base
                )
                var bufferList = AudioBufferList(mNumberBuffers: 1, mBuffers: buffer)
                let status = ExtAudioFileWrite(file, UInt32(n), &bufferList)
                if status != noErr {
                    logger.error("Leading-silence write failed: \(status)")
                    return
                }
                framesRemaining -= n
            }
        }
    }

    // MARK: - IOProc

    private func startIOProc() throws {
        let ring = ringBuffer

        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(
            &procID,
            aggregateDeviceID,
            nil
        ) { _, inInputData, inInputTime, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inInputData)
            )

            guard let firstBuffer = buffers.first,
                  firstBuffer.mData != nil else { return }

            let frameCount = audioFrameCount(
                byteSize: firstBuffer.mDataByteSize,
                channelCount: firstBuffer.mNumberChannels
            )
            guard frameCount > 0 else { return }

            // Lock-free enqueue into pre-allocated ring buffer slots.
            // No heap allocation, no locks. If ring is full or buffer exceeds
            // slot size, the drop is counted atomically. The frame's host time
            // travels with it so the writer can align the track start.
            _ = ring.enqueue(
                bufferList: inInputData,
                frameCount: frameCount,
                hostTime: inInputTime.pointee.mHostTime
            )
        }

        guard status == noErr, let id = procID else {
            throw AudioLabError.failedToCreateIOProc(status)
        }
        ioProcID = id

        let startStatus = AudioDeviceStart(aggregateDeviceID, id)
        guard startStatus == noErr else {
            throw AudioLabError.failedToStartDevice(startStatus)
        }
    }

    // MARK: - Teardown

    /// Cleans up any state created during a partial `start()` failure.
    /// Safe to call at any point during setup -- only tears down resources
    /// that were actually created. Unlike `teardown()`, this does not
    /// unconditionally wait on the writer semaphore (which would deadlock
    /// if the writer thread was never started).
    private func teardownPartialState() {
        if let procID = ioProcID {
            AudioDeviceStop(aggregateDeviceID, procID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
            ioProcID = nil
        }

        // Only signal and join the writer thread if it was actually started.
        // writerDone starts at 0, so waiting without a prior signal() deadlocks.
        if writerThread != nil {
            writerRunning.store(0, ordering: .releasing)
            writerDone.wait()
            writerThread = nil
        }

        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }

        if tapObjectID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapObjectID)
            tapObjectID = kAudioObjectUnknown
        }

        if let file = audioFile {
            ExtAudioFileDispose(file)
            audioFile = nil
        }
    }

    private func teardown() {
        // Stop the IOProc first so no new buffers are enqueued
        if let procID = ioProcID {
            AudioDeviceStop(aggregateDeviceID, procID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
            ioProcID = nil
        }

        // Signal writer thread to stop, then wait for it to fully drain and exit
        writerRunning.store(0, ordering: .releasing)
        writerDone.wait()
        writerThread = nil

        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }

        if tapObjectID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapObjectID)
            tapObjectID = kAudioObjectUnknown
        }

        if let file = audioFile {
            ExtAudioFileDispose(file)
            audioFile = nil
        }
    }

    deinit {
        if _isCapturing {
            teardown()
        }
    }
}

// MARK: - Helpers

/// Computes the number of audio frames from a buffer's byte size and
/// channel count, assuming 32-bit float samples.
///
/// `mDataByteSize = frameCount * channelCount * sizeof(Float)`
///
/// Returns 0 if `channelCount` is 0 or `byteSize` is 0.
func audioFrameCount(byteSize: UInt32, channelCount: UInt32) -> UInt32 {
    let ch = max(channelCount, 1)
    let bytesPerFrame = UInt32(MemoryLayout<Float>.size) * ch
    guard bytesPerFrame > 0 else { return 0 }
    return byteSize / bytesPerFrame
}

enum AudioLabError: LocalizedError {
    case failedToCreateProcessTap(OSStatus)
    case failedToCreateAggregateDevice(OSStatus)
    case couldNotQueryTapFormat
    case couldNotQueryOutputDevice
    case failedToCreateAudioFile(OSStatus)
    case failedToSetClientFormat(OSStatus)
    case failedToCreateIOProc(OSStatus)
    case failedToStartDevice(OSStatus)
    case failedToSetEncoderBitRate(OSStatus)
    case micSessionStartFailed(Error)

    var errorDescription: String? {
        switch self {
        case .failedToCreateProcessTap(let s):
            return "Failed to create process tap (OSStatus \(s))"
        case .failedToCreateAggregateDevice(let s):
            return "Failed to create aggregate device (OSStatus \(s))"
        case .couldNotQueryTapFormat:
            return "Could not query tap format"
        case .couldNotQueryOutputDevice:
            return "Could not determine default output device"
        case .failedToCreateAudioFile(let s):
            return "Failed to create audio file (OSStatus \(s))"
        case .failedToSetClientFormat(let s):
            return "Failed to set client format (OSStatus \(s))"
        case .failedToCreateIOProc(let s):
            return "Failed to create IO proc (OSStatus \(s))"
        case .failedToStartDevice(let s):
            return "Failed to start device (OSStatus \(s))"
        case .failedToSetEncoderBitRate(let s):
            return "Failed to set encoder bit rate (OSStatus \(s))"
        case .micSessionStartFailed(let error):
            return "Mic capture session start failed: \(error.localizedDescription)"
        }
    }
}
