import AVFoundation
import CoreAudio
import Foundation
import Synchronization
import os

private let logger = Logger(subsystem: "com.steak.experiments.audiolab", category: "SystemAudioCapture")

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

    private var _lock = os_unfair_lock()
    private var _isCapturing = false

    var isCapturing: Bool {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        return _isCapturing
    }

    var isSuspectedFailure: Bool {
        rmsMonitor.isSuspectedFailure
    }

    init(fileURL: URL, captureMode: CaptureMode, targetProcessID: AudioObjectID? = nil) {
        self.fileURL = fileURL
        self.captureMode = captureMode
        self.targetProcessID = targetProcessID
    }

    func start() throws {
        os_unfair_lock_lock(&_lock)
        guard !_isCapturing else {
            os_unfair_lock_unlock(&_lock)
            return
        }
        os_unfair_lock_unlock(&_lock)

        try createTapAndAggregate()
        try openAudioFile()
        startWriterThread()
        try startIOProc()

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
        let tapDesc = CATapDescription()
        tapDesc.uuid = tapUUID
        tapDesc.name = "audiolab-system-tap"

        if captureMode == .perProcess, let processID = targetProcessID {
            tapDesc.processes = [processID]
        }

        tapDesc.isPrivate = true
        tapDesc.muteBehavior = .unmuted
        tapDesc.isExclusive = false
        tapDesc.isMixdown = true

        var tapID: AudioObjectID = kAudioObjectUnknown
        var status = AudioHardwareCreateProcessTap(tapDesc, &tapID)
        guard status == noErr else {
            throw AudioLabError.failedToCreateProcessTap(status)
        }
        tapObjectID = tapID

        let aggConfig: [String: Any] = [
            kAudioAggregateDeviceUIDKey as String: tapUUID.uuidString,
            kAudioAggregateDeviceNameKey as String: "AudioLab Aggregate",
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
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

        var outputASBD = makeOutputASBD()
        var fileRef: ExtAudioFileRef?
        let status = ExtAudioFileCreateWithURL(
            fileURL as CFURL,
            kAudioFileCAFType,
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

    private func makeOutputASBD() -> AudioStreamBasicDescription {
        var asbd = AudioStreamBasicDescription()
        asbd.mSampleRate = EncoderSettings.sampleRate
        asbd.mFormatID = EncoderSettings.formatID
        asbd.mChannelsPerFrame = UInt32(EncoderSettings.channels)
        return asbd
    }

    // MARK: - Writer Thread

    private func startWriterThread() {
        writerRunning.store(1, ordering: .releasing)
        rmsMonitor.reset()

        let thread = Thread { [weak self] in
            self?.writerLoop()
        }
        thread.name = "com.steak.audiolab.system-writer"
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
        let frameCount = Int(entry.frameCount)
        let sampleRate = tapSampleRate

        // RMS monitoring -- runs on writer thread, not RT thread
        entry.data.withMemoryRebound(to: Float.self, capacity: frameCount) { samples in
            let duration = Double(frameCount) / sampleRate
            rmsMonitor.processSamples(samples, count: frameCount, bufferDuration: duration)
        }

        // Write to file -- runs on writer thread, not RT thread
        if let file = audioFile {
            let buffer = AudioBuffer(
                mNumberChannels: entry.channelCount,
                mDataByteSize: entry.dataByteSize,
                mData: entry.data
            )
            var bufferList = AudioBufferList(mNumberBuffers: 1, mBuffers: buffer)
            let writeStatus = ExtAudioFileWrite(file, UInt32(frameCount), &bufferList)
            if writeStatus != noErr {
                logger.fault("ExtAudioFileWrite failed: \(writeStatus)")
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
        ) { inNow, inInputData, inInputTime, outOutputData, inOutputTime in
            let buffers = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inInputData)
            )

            guard let firstBuffer = buffers.first,
                  firstBuffer.mData != nil else { return }

            let frameCount = firstBuffer.mDataByteSize / UInt32(MemoryLayout<Float>.size)
            guard frameCount > 0 else { return }

            // Lock-free enqueue into pre-allocated ring buffer slots.
            // No heap allocation, no locks. If ring is full or buffer exceeds
            // slot size, the drop is counted atomically.
            _ = ring.enqueue(bufferList: inInputData, frameCount: frameCount)
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

enum AudioLabError: LocalizedError {
    case failedToCreateProcessTap(OSStatus)
    case failedToCreateAggregateDevice(OSStatus)
    case couldNotQueryTapFormat
    case failedToCreateAudioFile(OSStatus)
    case failedToSetClientFormat(OSStatus)
    case failedToCreateIOProc(OSStatus)
    case failedToStartDevice(OSStatus)
    case micEngineStartFailed(Error)

    var errorDescription: String? {
        switch self {
        case .failedToCreateProcessTap(let s):
            return "Failed to create process tap (OSStatus \(s))"
        case .failedToCreateAggregateDevice(let s):
            return "Failed to create aggregate device (OSStatus \(s))"
        case .couldNotQueryTapFormat:
            return "Could not query tap format"
        case .failedToCreateAudioFile(let s):
            return "Failed to create audio file (OSStatus \(s))"
        case .failedToSetClientFormat(let s):
            return "Failed to set client format (OSStatus \(s))"
        case .failedToCreateIOProc(let s):
            return "Failed to create IO proc (OSStatus \(s))"
        case .failedToStartDevice(let s):
            return "Failed to start device (OSStatus \(s))"
        case .micEngineStartFailed(let error):
            return "Mic engine start failed: \(error.localizedDescription)"
        }
    }
}
