import AVFoundation
import CoreAudio
import Foundation
import os
import Synchronization

private let logger = Logger(subsystem: "net.scosman.biscotti.audiocapture", category: "LiveSystemCapture")

/// Live system-audio capture via Core Audio global process tap.
///
/// Creates a process tap + aggregate device referencing the default output
/// device, installs an IOProc that copies buffers through a lock-free ring
/// buffer to a writer thread, which writes PCM to a CAF file.
///
/// This is a thin hardware adapter -- all orchestration lives in
/// `AudioRecorder`. Tested only by the Manual Test App.
///
/// **Thread-safety contract:** this class is `@unchecked Sendable` because
/// its mutable state (`tapObjectID`, `aggregateDeviceID`, `ioProcID`,
/// `audioFile`, `writerThread`, etc.) is only mutated in `start()`,
/// `stop()`, `reconnect()`, and `teardown()`. All of these are called
/// exclusively by `AudioRecorder` (an actor), which serializes access.
/// The `capturingFlag` atomic provides a fast non-blocking read for the
/// `start()` early-return guard and `deinit`. The writer thread
/// communicates errors via `_lock`-protected `_writeError`, accessed only
/// at teardown after the writer thread has joined.
final class LiveSystemCaptureEngine: CaptureEngine, @unchecked Sendable {
    private var tapObjectID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?

    private var audioFile: ExtAudioFileRef?
    private let ringBuffer = AudioRingBuffer(capacity: 512, maxFrameCount: 8192)
    private var writerThread: Thread?
    private let writerRunning = Atomic<Int>(0)
    private let writerDone = DispatchSemaphore(value: 0)
    private var tapSampleRate: Double = 24000

    /// Atomic state flag -- avoids os_unfair_lock in async contexts.
    private let capturingFlag = Atomic<Bool>(false)

    private var _lock = os_unfair_lock()
    private var _writeError: OSStatus?

    /// Buffer samples fed to the permission checker for zero-detection.
    let permissionChecker: LiveSystemPermissionChecker

    init(permissionChecker: LiveSystemPermissionChecker = LiveSystemPermissionChecker()) {
        self.permissionChecker = permissionChecker
    }

    func start(writingTo url: URL) async throws {
        guard !capturingFlag.load(ordering: .acquiring) else { return }

        try createTapAndAggregate()
        try openAudioFile(url: url)
        startWriterThread()
        try startIOProc()

        capturingFlag.store(true, ordering: .releasing)
    }

    func stop() async {
        guard capturingFlag.exchange(false, ordering: .acquiringAndReleasing) else { return }
        teardown()
    }

    /// Reconnects hardware without reopening the audio file (preserves audio).
    /// Called by `AudioRecorder` on output-device route changes.
    func reconnect() async throws {
        guard capturingFlag.load(ordering: .acquiring) else { return }
        teardownHardware()
        do {
            try createTapAndAggregate()
            startWriterThread()
            try startIOProc()
        } catch {
            capturingFlag.store(false, ordering: .releasing)
            throw error
        }
    }

    // MARK: - Setup

    private func createTapAndAggregate() throws {
        guard let outputDeviceID = CoreAudioHelpers.defaultOutputDeviceID(),
              let outputUID = CoreAudioHelpers.deviceUID(for: outputDeviceID)
        else {
            throw CaptureError.tapCreationFailed(-1)
        }

        let tapUUID = UUID()
        let tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tapDesc.uuid = tapUUID
        tapDesc.name = "biscotti-system-tap"
        tapDesc.muteBehavior = .unmuted
        tapDesc.isPrivate = true

        var tapID: AudioObjectID = kAudioObjectUnknown
        var status = AudioHardwareCreateProcessTap(tapDesc, &tapID)
        guard status == noErr else {
            throw CaptureError.tapCreationFailed(status)
        }
        tapObjectID = tapID

        let aggregateUID = UUID().uuidString
        let aggConfig: [String: Any] = [
            kAudioAggregateDeviceUIDKey as String: aggregateUID,
            kAudioAggregateDeviceNameKey as String: "Biscotti Aggregate",
            kAudioAggregateDeviceMainSubDeviceKey as String: outputUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [kAudioSubDeviceUIDKey as String: outputUID]
            ],
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: tapUUID.uuidString,
                    kAudioSubTapDriftCompensationKey as String: true
                ]
            ]
        ]

        var aggID: AudioObjectID = kAudioObjectUnknown
        status = AudioHardwareCreateAggregateDevice(aggConfig as CFDictionary, &aggID)
        guard status == noErr else {
            AudioHardwareDestroyProcessTap(tapObjectID)
            tapObjectID = kAudioObjectUnknown
            throw CaptureError.aggregateDeviceFailed(status)
        }
        aggregateDeviceID = aggID
    }

    private func openAudioFile(url: URL) throws {
        guard let tapFormat = queryTapFormat() else {
            throw CaptureError.tapCreationFailed(-2)
        }

        tapSampleRate = tapFormat.mSampleRate

        // Write PCM CAF (crash-safe).
        var cafASBD = AudioStreamBasicDescription(
            mSampleRate: tapFormat.mSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: tapFormat.mBytesPerPacket,
            mFramesPerPacket: 1,
            mBytesPerFrame: tapFormat.mBytesPerFrame,
            mChannelsPerFrame: tapFormat.mChannelsPerFrame,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        var fileRef: ExtAudioFileRef?
        let status = ExtAudioFileCreateWithURL(
            url as CFURL,
            kAudioFileCAFType,
            &cafASBD,
            nil,
            AudioFileFlags.eraseFile.rawValue,
            &fileRef
        )
        guard status == noErr, let file = fileRef else {
            throw CaptureError.tapCreationFailed(status)
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
        let thread = Thread { [weak self] in self?.writerLoop() }
        thread.name = "net.scosman.biscotti.system-writer"
        thread.qualityOfService = .userInteractive
        writerThread = thread
        thread.start()
    }

    private func writerLoop() {
        while writerRunning.load(ordering: .acquiring) == 1 {
            var didWork = false
            while let entry = ringBuffer.dequeue() {
                didWork = true; processEntry(entry)
            }
            if !didWork { Thread.sleep(forTimeInterval: 0.001) }
        }
        while let entry = ringBuffer.dequeue() {
            processEntry(entry)
        }
        let dropped = ringBuffer.droppedBuffers.load(ordering: .acquiring)
        if dropped > 0 { logger.warning("Ring buffer dropped \(dropped) buffer(s)") }
        writerDone.signal()
    }

    private func processEntry(_ entry: AudioRingBuffer.Entry) {
        let frameCount = Int(entry.frameCount)
        let channelCount = Int(max(entry.channelCount, 1))
        let sampleCount = frameCount * channelCount

        // Feed samples to permission checker for zero-detection, but only
        // during the initial ~2 s window. After the window closes, skip the
        // per-buffer copy entirely to avoid allocating on every callback.
        if permissionChecker.isWithinCheckWindow {
            entry.data.withMemoryRebound(to: Float.self, capacity: sampleCount) { samples in
                let bufferPointer = UnsafeBufferPointer(start: samples, count: sampleCount)
                let duration = Double(frameCount) / tapSampleRate
                permissionChecker.ingestSamples(bufferPointer, duration: duration)
            }
        }

        guard let file = audioFile else { return }

        let expectedBytes = UInt32(sampleCount) * UInt32(MemoryLayout<Float>.size)
        guard entry.dataByteSize >= expectedBytes else {
            logger.error("Buffer byte size mismatch -- skipping write")
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
            recordWriteError(writeStatus)
        }
    }

    private func recordWriteError(_ status: OSStatus) {
        os_unfair_lock_lock(&_lock)
        if _writeError == nil { _writeError = status }
        os_unfair_lock_unlock(&_lock)
    }

    // MARK: - IOProc

    private func startIOProc() throws {
        let ring = ringBuffer

        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(
            &procID,
            aggregateDeviceID,
            nil
        ) { _, inInputData, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inInputData)
            )

            guard let firstBuffer = buffers.first,
                  firstBuffer.mData != nil
            else { return }

            let frameCount = audioFrameCount(
                byteSize: firstBuffer.mDataByteSize,
                channelCount: firstBuffer.mNumberChannels
            )
            guard frameCount > 0 else { return }

            _ = ring.enqueue(bufferList: inInputData, frameCount: frameCount)
        }

        guard status == noErr, let id = procID else {
            throw CaptureError.tapCreationFailed(status)
        }
        ioProcID = id

        let startStatus = AudioDeviceStart(aggregateDeviceID, id)
        guard startStatus == noErr else {
            throw CaptureError.tapCreationFailed(startStatus)
        }
    }

    // MARK: - Teardown

    /// Tears down the hardware pipeline but keeps the audio file open.
    private func teardownHardware() {
        if let procID = ioProcID {
            AudioDeviceStop(aggregateDeviceID, procID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
            ioProcID = nil
        }

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
    }

    /// Full teardown: hardware pipeline + audio file.
    private func teardown() {
        teardownHardware()

        if let file = audioFile {
            ExtAudioFileDispose(file)
            audioFile = nil
        }
    }

    deinit {
        if capturingFlag.load(ordering: .acquiring) {
            teardown()
        }
    }
}
