import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import os
import Synchronization

private let logger = Logger(subsystem: "net.scosman.biscotti.audiocapture", category: "LiveSystemCapture")

/// Live system-audio capture via Core Audio global process tap.
///
/// Creates a process tap + aggregate device, installs an IOProc that
/// copies buffers through a lock-free ring buffer to a writer thread
/// which writes ADTS AAC via `ExtAudioFile`. Thin hardware adapter --
/// orchestration lives in `AudioRecorder`. Tested by Manual Test App.
///
/// **Thread-safety:** `@unchecked Sendable` — mutable state serialized
/// by the owning `AudioRecorder` actor. Writer-thread errors flow
/// through `_lock`-protected `_writeError`, read after the writer joins.
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

    /// Writer-thread-only flags for deferred client format setup.
    private var clientFormatConfigured = false
    private var clientFormatFailed = false

    #if DEBUG
        nonisolated(unsafe) static var verboseDiagnostics = true
        private let diagHeartbeat = SystemCaptureDiagnostics.Heartbeat()
    #endif

    private let capturingFlag = Atomic<Bool>(false)
    private var _lock = os_unfair_lock()
    private var _writeError: OSStatus?

    /// Buffer samples fed to the permission checker for zero-detection.
    let permissionChecker: LiveSystemPermissionChecker

    /// Encoder settings used for ADTS AAC file creation.
    private let encoder: EncoderSettings

    init(
        permissionChecker: LiveSystemPermissionChecker = LiveSystemPermissionChecker(),
        encoder: EncoderSettings = .voice
    ) {
        self.permissionChecker = permissionChecker
        self.encoder = encoder
    }

    func start(writingTo url: URL) async throws {
        guard !capturingFlag.load(ordering: .acquiring) else { return }

        try createTapAndAggregate()
        #if DEBUG
            if Self.verboseDiagnostics {
                SystemCaptureDiagnostics.logSetupFormats(
                    tapObjectID: tapObjectID,
                    aggregateDeviceID: aggregateDeviceID
                )
            }
        #endif
        try openAudioFile(url: url)
        startWriterThread()
        try startIOProc()

        capturingFlag.store(true, ordering: .releasing)
    }

    func stop() async {
        guard capturingFlag.exchange(false, ordering: .acquiringAndReleasing) else { return }
        teardown()
    }

    /// Reconnects hardware without reopening the audio file. Client format
    /// (channel count) is locked to the first device for the file's life.
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
        // Mono mixdown global tap — the tap itself mixes all system audio
        // to a single channel, so the IOProc gets a clean mono feed
        // regardless of the output device's speaker topology.
        let tapDesc = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        tapDesc.name = "biscotti-system-tap"
        tapDesc.muteBehavior = .unmuted
        tapDesc.isPrivate = true

        var tapID: AudioObjectID = kAudioObjectUnknown
        var status = AudioHardwareCreateProcessTap(tapDesc, &tapID)
        guard status == noErr else {
            throw CaptureError.tapCreationFailed(status)
        }
        tapObjectID = tapID

        // Get the tap's UID for attaching to the aggregate device.
        let tapUID = try queryTapUID()

        // Empty-sub-device aggregate (mirrors audiotee). The sub-device list
        // is intentionally empty — we do NOT add the output device, which
        // would cause the IOProc to deliver the raw multichannel speaker feed
        // instead of the tap's clean mono mixdown.
        let aggConfig: [String: Any] = [
            kAudioAggregateDeviceUIDKey as String: UUID().uuidString,
            kAudioAggregateDeviceNameKey as String: "Biscotti Aggregate",
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceSubDeviceListKey as String: [] as CFArray
        ]

        var aggID: AudioObjectID = kAudioObjectUnknown
        status = AudioHardwareCreateAggregateDevice(aggConfig as CFDictionary, &aggID)
        guard status == noErr else {
            AudioHardwareDestroyProcessTap(tapObjectID)
            tapObjectID = kAudioObjectUnknown
            throw CaptureError.aggregateDeviceFailed(status)
        }
        aggregateDeviceID = aggID

        // Attach the tap to the aggregate via kAudioAggregateDevicePropertyTapList.
        try attachTapToAggregate(tapUID: tapUID)
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

        // Feed samples to permission checker during initial ~2 s window.
        if permissionChecker.isWithinCheckWindow {
            entry.data.withMemoryRebound(to: Float.self, capacity: sampleCount) { samples in
                let bufferPointer = UnsafeBufferPointer(start: samples, count: sampleCount)
                let duration = Double(frameCount) / tapSampleRate
                permissionChecker.ingestSamples(bufferPointer, duration: duration)
            }
        }

        guard let file = audioFile else { return }
        guard !clientFormatFailed else { return }

        // First buffer: set client format from actual delivered channel
        // count (ground truth). ExtAudioFile handles N-ch → mono downmix.
        if !clientFormatConfigured {
            if configureClientFormat(
                channelCount: UInt32(channelCount), file: file
            ) {
                clientFormatConfigured = true
            } else {
                clientFormatFailed = true
                return
            }
        }

        #if DEBUG
            if Self.verboseDiagnostics {
                diagHeartbeat.processBuffer(
                    data: entry.data, frameCount: frameCount,
                    channelCount: channelCount,
                    dataByteSize: entry.dataByteSize,
                    sampleRate: tapSampleRate
                )
            }
        #endif

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

// MARK: - Tap / Aggregate Helpers + Audio File Setup

extension LiveSystemCaptureEngine {
    /// Queries the tap's UID string from kAudioTapPropertyUID.
    private func queryTapUID() throws -> CFString {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString>.size)
        var uid: CFString = "" as CFString
        let status = withUnsafeMutablePointer(to: &uid) { ptr in
            AudioObjectGetPropertyData(tapObjectID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr else {
            throw CaptureError.tapCreationFailed(status)
        }
        return uid
    }

    /// Attaches a tap to the aggregate device via the TapList property.
    private func attachTapToAggregate(tapUID: CFString) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyTapList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let tapArray = [tapUID] as CFArray
        let size = UInt32(MemoryLayout<CFArray>.size)
        let status = withUnsafePointer(to: tapArray) { ptr in
            AudioObjectSetPropertyData(aggregateDeviceID, &address, 0, nil, size, ptr)
        }
        guard status == noErr else {
            throw CaptureError.tapCreationFailed(status)
        }
    }

    private func openAudioFile(url: URL) throws {
        guard let tapFormat = queryTapFormat() else {
            throw CaptureError.tapCreationFailed(-2)
        }

        tapSampleRate = tapFormat.mSampleRate
        clientFormatConfigured = false
        clientFormatFailed = false

        // Create ADTS AAC file. Client format deferred to processEntry()
        // where the actual channel count is known from IOProc data.
        var outputASBD = encoder.outputASBD()
        var fileRef: ExtAudioFileRef?
        let createStatus = ExtAudioFileCreateWithURL(
            url as CFURL,
            encoder.fileType,
            &outputASBD,
            nil,
            AudioFileFlags.eraseFile.rawValue,
            &fileRef
        )
        guard createStatus == noErr, let file = fileRef else {
            throw CaptureError.tapCreationFailed(createStatus)
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

    /// Sets client format (interleaved float PCM) and encoder bit rate.
    /// Returns `true` on success.
    private func configureClientFormat(
        channelCount: UInt32, file: ExtAudioFileRef
    ) -> Bool {
        let bytesPerFrame = UInt32(MemoryLayout<Float>.size) * channelCount
        var clientASBD = AudioStreamBasicDescription(
            mSampleRate: tapSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: channelCount,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        let clientStatus = ExtAudioFileSetProperty(
            file,
            kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
            &clientASBD
        )
        guard clientStatus == noErr else {
            logger.error("Failed to set client format (\(channelCount) ch): \(clientStatus)")
            recordWriteError(clientStatus)
            return false
        }

        let brStatus = EncoderSettings.applyBitRate(to: file, bitRate: encoder.bitRate)
        if brStatus != noErr {
            logger.warning("applyBitRate returned \(brStatus) — using encoder default")
        }
        return true
    }
}

// MARK: - DEBUG Diagnostics (compiled out of release)

#if DEBUG

    /// Format/structure logging and per-channel heartbeat for diagnosing
    /// muffled system audio on multichannel devices.
    enum SystemCaptureDiagnostics {
        // MARK: - Format snapshot (called once at start)

        static func logSetupFormats(
            tapObjectID: AudioObjectID,
            aggregateDeviceID: AudioObjectID
        ) {
            logTapFormat(tapObjectID: tapObjectID)
            logAggregateInputFormat(deviceID: aggregateDeviceID)
            logAggregateInputLayout(deviceID: aggregateDeviceID)
            logDefaultOutputDevice()
        }

        private static func logTapFormat(tapObjectID: AudioObjectID) {
            var format = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioTapPropertyFormat,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let status = AudioObjectGetPropertyData(
                tapObjectID, &address, 0, nil, &size, &format
            )
            if status == noErr {
                let flags = String(format: "0x%08X", format.mFormatFlags)
                logger.info(
                    "[diag] tap format: rate=\(format.mSampleRate) ch=\(format.mChannelsPerFrame) flags=\(flags)"
                )
            } else {
                logger.warning("[diag] tap format query failed: \(status)")
            }
        }

        private static func logAggregateInputFormat(deviceID: AudioObjectID) {
            if let fmt = CoreAudioHelpers.streamFormat(
                for: deviceID, scope: kAudioDevicePropertyScopeInput
            ) {
                let flags = String(format: "0x%08X", fmt.mFormatFlags)
                logger.info(
                    "[diag] aggregate input stream: rate=\(fmt.mSampleRate) ch=\(fmt.mChannelsPerFrame) flags=\(flags)"
                )
            } else {
                logger.warning("[diag] aggregate input stream format query failed")
            }
        }

        private static func logAggregateInputLayout(deviceID: AudioObjectID) {
            guard let data = CoreAudioHelpers.channelLayoutData(
                for: deviceID, scope: kAudioDevicePropertyScopeInput
            ) else {
                logger.info("[diag] aggregate input channel layout: not available")
                return
            }

            data.withUnsafeBytes { rawBuf in
                guard rawBuf.count >= MemoryLayout<AudioChannelLayout>.size else {
                    logger.warning("[diag] channel layout data too small")
                    return
                }
                let layout = rawBuf.load(as: AudioChannelLayout.self)
                let tag = layout.mChannelLayoutTag
                let tagHex = String(format: "0x%08X", tag)
                let tagName = readableLayoutTag(tag)
                logger.info(
                    "[diag] aggregate input layout tag=\(tagHex) (\(tagName)) bitmap=\(layout.mChannelBitmap.rawValue)"
                )

                if tag == kAudioChannelLayoutTag_UseChannelDescriptions {
                    logChannelDescriptions(rawBuf: rawBuf, count: Int(layout.mNumberChannelDescriptions))
                }
            }
        }

        private static func logChannelDescriptions(
            rawBuf: UnsafeRawBufferPointer, count: Int
        ) {
            guard let descOffset = MemoryLayout<AudioChannelLayout>.offset(
                of: \AudioChannelLayout.mChannelDescriptions
            ) else { return }
            let descStride = MemoryLayout<AudioChannelDescription>.stride
            var labels: [String] = []
            for idx in 0 ..< count {
                let off = descOffset + idx * descStride
                guard off + descStride <= rawBuf.count else { break }
                let desc = rawBuf.load(
                    fromByteOffset: off, as: AudioChannelDescription.self
                )
                labels.append("\(desc.mChannelLabel)")
            }
            let labelsStr = labels.joined(separator: ", ")
            logger.info("[diag] channel labels: [\(labelsStr)]")
        }

        private static func logDefaultOutputDevice() {
            guard let devID = CoreAudioHelpers.defaultOutputDeviceID() else {
                logger.warning("[diag] no default output device")
                return
            }
            let name = CoreAudioHelpers.deviceName(for: devID) ?? "unknown"
            let rate = CoreAudioHelpers.nominalSampleRate(for: devID) ?? 0
            let channels = CoreAudioHelpers.channelCount(
                for: devID, scope: kAudioDevicePropertyScopeOutput
            ) ?? 0
            let transport = CoreAudioHelpers.transportType(for: devID) ?? 0
            let transportHex = String(format: "0x%08X", transport)
            logger.info(
                "[diag] default output: \"\(name)\" rate=\(rate) ch=\(channels) transport=\(transportHex)"
            )
        }

        private static func readableLayoutTag(_ tag: AudioChannelLayoutTag) -> String {
            switch tag {
            case kAudioChannelLayoutTag_Mono: "Mono"
            case kAudioChannelLayoutTag_Stereo: "Stereo"
            case kAudioChannelLayoutTag_StereoHeadphones: "StereoHeadphones"
            case kAudioChannelLayoutTag_MPEG_5_1_A: "5.1(A)"
            case kAudioChannelLayoutTag_MPEG_5_1_B: "5.1(B)"
            case kAudioChannelLayoutTag_MPEG_7_1_A: "7.1(A)"
            case kAudioChannelLayoutTag_UseChannelDescriptions: "UseChannelDescriptions"
            case kAudioChannelLayoutTag_UseChannelBitmap: "UseChannelBitmap"
            default: "tag(\(tag))"
            }
        }

        // MARK: - Per-channel heartbeat accumulator

        /// Accumulates per-channel peak and HF-proxy metrics over a ~2 s
        /// window, then logs a single summary line. Writer-thread only.
        final class Heartbeat {
            private var channelPeaks: [Float] = []
            private var channelHFSum: [Float] = []
            private var channelPrevSample: [Float] = []
            private var sampleCount: Int = 0
            private var lastLogTime: UInt64 = 0
            private var isFirstBuffer = true
            private let heartbeatNanos: UInt64 = 2_000_000_000

            func processBuffer(
                data: UnsafeMutableRawPointer,
                frameCount: Int,
                channelCount: Int,
                dataByteSize: UInt32,
                sampleRate: Double
            ) {
                let totalSamples = frameCount * channelCount
                guard totalSamples > 0 else { return }

                if isFirstBuffer {
                    let msg = "ch=\(channelCount) frames=\(frameCount) bytes=\(dataByteSize) rate=\(sampleRate)"
                    logger.info("[diag] first buffer: \(msg)")
                    isFirstBuffer = false
                    lastLogTime = mach_absolute_time()
                }

                if channelPeaks.count != channelCount {
                    resetAccumulators(channelCount: channelCount)
                }

                data.withMemoryRebound(to: Float.self, capacity: totalSamples) { samples in
                    for frame in 0 ..< frameCount {
                        let base = frame * channelCount
                        for channel in 0 ..< channelCount {
                            let val = samples[base + channel]
                            let absVal = abs(val)
                            if absVal > channelPeaks[channel] {
                                channelPeaks[channel] = absVal
                            }
                            let diff = abs(val - channelPrevSample[channel])
                            channelHFSum[channel] += diff
                            channelPrevSample[channel] = val
                        }
                    }
                }

                sampleCount += frameCount

                let now = mach_absolute_time()
                if machToNanos(now &- lastLogTime) >= heartbeatNanos {
                    emitHeartbeat(channelCount: channelCount)
                    resetAccumulators(channelCount: channelCount)
                    lastLogTime = now
                }
            }

            private func emitHeartbeat(channelCount: Int) {
                guard sampleCount > 0 else { return }
                let count = Float(sampleCount)
                var parts: [String] = []
                for channel in 0 ..< channelCount {
                    let peak = channelPeaks[channel]
                    let hfProxy = channelHFSum[channel] / count
                    let peakStr = String(format: "%.4f", peak)
                    let hfStr = String(format: "%.4f", hfProxy)
                    parts.append("ch\(channel) peak=\(peakStr) hf=\(hfStr)")
                }
                let summary = parts.joined(separator: " | ")
                logger.info("[diag] system heartbeat: \(summary)")
            }

            private func resetAccumulators(channelCount: Int) {
                channelPeaks = [Float](repeating: 0, count: channelCount)
                channelHFSum = [Float](repeating: 0, count: channelCount)
                channelPrevSample = [Float](repeating: 0, count: channelCount)
                sampleCount = 0
            }

            private func machToNanos(_ ticks: UInt64) -> UInt64 {
                var info = mach_timebase_info_data_t()
                mach_timebase_info(&info)
                return ticks * UInt64(info.numer) / UInt64(info.denom)
            }
        }
    }

#endif
