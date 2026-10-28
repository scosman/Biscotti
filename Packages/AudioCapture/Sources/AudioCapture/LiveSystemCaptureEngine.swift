import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import os
import QuartzCore
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
final class LiveSystemCaptureEngine: CaptureEngine, @unchecked Sendable { // swiftlint:disable:this type_body_length
    private var tapObjectID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?

    private var audioFile: ExtAudioFileRef?
    private let ringBuffer = AudioRingBuffer(capacity: 512, maxFrameCount: 8192)
    private var writerThread: Thread?
    private let writerRunning = Atomic<Int>(0)
    private let writerDone = DispatchSemaphore(value: 0)
    private var tapSampleRate: Double = 24000
    private let gapFillWriter = SystemGapFillWriter()

    /// Converts each tap buffer to the file's fixed client format.
    /// Writer-thread only; replaced for each new file.
    private var formatConverter = SystemFormatConverter()

    // MARK: - Two-track alignment

    /// Host-clock seconds of the mic's first delivered sample -- the
    /// recording's t=0. The system track is padded with leading silence
    /// so its first real frame lines up with the mic. Set via
    /// `setMicAnchor(_:)` before `start()`.
    private var micAnchorSeconds: Double = 0

    /// `CACurrentMediaTime()` captured in `start()`. Wall-clock upper bound
    /// on leading silence: the gap can't exceed how long the system capture
    /// has actually been running. Guards a bogus anchor from writing hours
    /// of silence.
    private var systemStartWall: CFTimeInterval = 0

    /// Writer-thread-only: whether leading silence has been written yet.
    private var didWriteLeadingSilence = false

    /// Absolute backstop on prepended silence (seconds).
    private static let maxLeadingSilenceSeconds: Double = 3600

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

    /// The Core Audio calls that need a real process tap.
    private let tapHardware: TapHardware

    init(
        permissionChecker: LiveSystemPermissionChecker = LiveSystemPermissionChecker(),
        encoder: EncoderSettings = .voice,
        tapHardware: TapHardware = .live
    ) {
        self.permissionChecker = permissionChecker
        self.encoder = encoder
        self.tapHardware = tapHardware
    }

    /// Stores the mic's first-buffer host-clock anchor so the writer thread
    /// can prepend leading silence on the system track's first buffer.
    func setMicAnchor(_ seconds: Double) {
        micAnchorSeconds = seconds
    }

    /// Non-nil if `ExtAudioFileWrite` failed during recording.
    var writeError: OSStatus? {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        return _writeError
    }

    func start(writingTo url: URL) async throws {
        guard !capturingFlag.load(ordering: .acquiring) else { return }

        // Clear any write error from a previous session (e.g. permission
        // probe) so a fresh start reports only its own errors.
        clearWriteError()

        // New session: restart the permission zero-detection window. A start()
        // can legitimately run again after a *failed* start (the recorder stays
        // retryable); without this the window stays closed and silent-system
        // detection is disabled on the retry.
        permissionChecker.reset()

        systemStartWall = CACurrentMediaTime()
        didWriteLeadingSilence = false
        gapFillWriter.reset()

        do {
            try tapHardware.create(self)

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
            try tapHardware.startIO(self, ringBuffer)
        } catch {
            // Partial-start cleanup. `startWriterThread()` launches a thread and
            // `openAudioFile()` opens the file *before* `startIOProc()`, so a
            // throw here would otherwise leak a running writer thread holding the
            // file open — which a later start() would compound into two writers
            // appending the same file concurrently (heap corruption). `teardown()`
            // is idempotent over partial state (each step guards on its handle).
            teardown()
            throw error
        }

        capturingFlag.store(true, ordering: .releasing)
    }

    func stop() async {
        guard capturingFlag.exchange(false, ordering: .acquiringAndReleasing) else { return }
        teardown()
    }

    /// Settle delay before reconnecting hardware after a device change.
    /// Gives the HAL time to stabilize after the route change; without this
    /// the new aggregate/tap can fail to start because the device graph is
    /// still reconfiguring. 200ms is based on observed Apple Silicon HAL
    /// device-graph reconfiguration times (typically 100-200ms).
    static let reconnectSettleDelay: Duration = .milliseconds(200)

    /// Reconnects hardware without reopening the audio file.
    ///
    /// Re-queries the new tap's format and updates `tapSampleRate`, so the
    /// writer reads the new IOProc's buffers at the right rate. The file's
    /// client format does not change: the writer converts every buffer to
    /// it (see `SystemFormatConverter`).
    ///
    /// A failed attempt releases the hardware but keeps the recording: the
    /// file stays open and `capturingFlag` stays set, so the next attempt (a
    /// retry or a later route change) rebuilds the tap and `stop()` still
    /// closes the file.
    ///
    /// Leading silence is NOT re-written: alignment was established on
    /// the first buffer of the session.
    func reconnect() async throws {
        guard capturingFlag.load(ordering: .acquiring) else { return }

        teardownHardware()

        // Let the HAL settle after the device change before creating new
        // hardware resources. Without this, the tap/aggregate creation can
        // fail intermittently because the device graph is mid-reconfiguration.
        try await Task.sleep(for: Self.reconnectSettleDelay)

        // A stop() during the settle delay ended the recording.
        guard capturingFlag.load(ordering: .acquiring) else { return }

        do {
            try tapHardware.create(self)

            // Without the new tap's rate, its buffers would be read at the
            // old one. Fail this attempt, like a failed tap creation, so the
            // recorder retries it.
            guard let tapFormat = usableTapFormat() else {
                logger.warning("Reconnect: the new tap has no usable format")
                throw CaptureError.tapCreationFailed(-2)
            }
            applyTapFormat(tapFormat)

            #if DEBUG
                if Self.verboseDiagnostics {
                    SystemCaptureDiagnostics.logSetupFormats(
                        tapObjectID: tapObjectID,
                        aggregateDeviceID: aggregateDeviceID
                    )
                }
            #endif

            startWriterThread()
            try tapHardware.startIO(self, ringBuffer)
        } catch {
            // Partial-reconnect cleanup: tear down any hardware and the
            // writer thread created before the throw. The recording stays
            // open (see above), so `capturingFlag` is left set.
            teardownHardware()
            throw error
        }
    }

    /// Applies the format of the tap that a reconnect just created. Only
    /// `tapSampleRate` changes. A stale rate would misread every buffer's
    /// duration and stretch or squeeze the track. The writer rebuilds its
    /// converter when the first buffer in the new format arrives; the
    /// file's client format stays fixed, because ExtAudioFile refuses a new
    /// one after the first write (`-66565`).
    ///
    /// Internal so tests can simulate a reconnect without hardware.
    func applyTapFormat(_ format: AudioStreamBasicDescription) {
        let previousRate = tapSampleRate
        tapSampleRate = format.mSampleRate
        logger.notice(
            "Reconnect: tap format \(format.mSampleRate, privacy: .public) Hz \(format.mChannelsPerFrame, privacy: .public) ch (was \(previousRate, privacy: .public) Hz)"
        )
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

    /// Writes one tap buffer, converted to the client format, plus any
    /// silence that must come before it. Writer-thread only; internal so
    /// tests can feed synthetic tap buffers through the real write path.
    func processEntry(_ entry: AudioRingBuffer.Entry) { // swiftlint:disable:this function_body_length
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

        // Before the first real frame, prepend leading silence so the
        // system track's first frame lines up with the mic's first frame
        // (the recording's t=0). Runs once, on the writer thread.
        if !didWriteLeadingSilence {
            didWriteLeadingSilence = true
            writeLeadingSilence(
                channelCount: SystemFormatConverter.clientFormat.channelCount,
                firstFrameHostTime: entry.hostTime,
                file: file
            )
        }

        // Fill any gap since the last buffer with silence so the system
        // track stays aligned with wall-clock time after reconnects.
        // Measured from IOProc host-clock timestamps (capture side),
        // not writer-thread timing. Silence is not fed to the permission
        // checker; a real gap-fill write failure IS recorded so the
        // session surfaces it.
        let hostNanos = AudioConvertHostTimeToNanos(entry.hostTime)
        gapFillWriter.processBuffer(
            hostTimeNanos: hostNanos,
            bufferFrameCount: entry.frameCount,
            bufferSampleRate: tapSampleRate,
            clientFormat: SystemFormatConverter.clientFormat,
            file: file
        )
        if let gapError = gapFillWriter.writeError {
            recordWriteError(gapError)
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

        guard let buffer = formatConverter.convert(entry, sampleRate: tapSampleRate) else { return }
        let writeStatus = ExtAudioFileWrite(file, buffer.frameLength, buffer.audioBufferList)
        if writeStatus != noErr {
            logger.error("ExtAudioFileWrite failed: \(writeStatus, privacy: .public)")
            recordWriteError(writeStatus)
        }
    }

    private nonisolated func recordWriteError(_ status: OSStatus) {
        os_unfair_lock_lock(&_lock)
        if _writeError == nil { _writeError = status }
        os_unfair_lock_unlock(&_lock)
    }

    private nonisolated func clearWriteError() {
        os_unfair_lock_lock(&_lock)
        _writeError = nil
        os_unfair_lock_unlock(&_lock)
    }

    // MARK: - Leading silence (two-track alignment)

    /// Writes `systemFirstFrame − micAnchor` worth of silent frames, in the
    /// client format, to the front of the file so the system track aligns
    /// with the mic track.
    /// `firstFrameHostTime` is the mach host time of the system tap's first
    /// captured frame; the gap to `micAnchorSeconds` is the precise start
    /// offset. Runs once on the writer thread (allocation is fine here).
    private func writeLeadingSilence(
        channelCount: UInt32,
        firstFrameHostTime: UInt64,
        file: ExtAudioFileRef
    ) {
        let hostNanos = AudioConvertHostTimeToNanos(firstFrameHostTime)
        var framesRemaining = leadingSilenceFrameCount(
            systemHostTimeNanos: hostNanos,
            micAnchorSeconds: micAnchorSeconds,
            systemStartWall: systemStartWall,
            currentWall: CACurrentMediaTime(),
            sampleRate: SystemFormatConverter.clientFormat.sampleRate,
            maxLeadingSilenceSeconds: Self.maxLeadingSilenceSeconds
        )
        guard framesRemaining > 0 else { return }

        logger.info("Aligning system track: prepending \(framesRemaining) frames of leading silence")

        let channels = Int(max(channelCount, 1))
        let chunkFrames = 8192
        var silence = [Float](repeating: 0, count: chunkFrames * channels)
        silence.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            while framesRemaining > 0 {
                let count = min(chunkFrames, framesRemaining)
                let buffer = AudioBuffer(
                    mNumberChannels: channelCount,
                    mDataByteSize: UInt32(count * channels * MemoryLayout<Float>.size),
                    mData: base
                )
                var bufferList = AudioBufferList(mNumberBuffers: 1, mBuffers: buffer)
                let status = ExtAudioFileWrite(file, UInt32(count), &bufferList)
                if status != noErr {
                    logger.error("Leading-silence write failed: \(status, privacy: .public)")
                    return
                }
                framesRemaining -= count
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
                  firstBuffer.mData != nil
            else { return }

            let frameCount = audioFrameCount(
                byteSize: firstBuffer.mDataByteSize,
                channelCount: firstBuffer.mNumberChannels
            )
            guard frameCount > 0 else { return }

            // Pass the frame's host time so the writer can align the system
            // track against the mic's first-frame anchor.
            _ = ring.enqueue(
                bufferList: inInputData,
                frameCount: frameCount,
                hostTime: inInputTime.pointee.mHostTime
            )
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

    /// Internal so tests can close a file written without a tap.
    func teardown() {
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

    /// Opens the recording's file for the tap that `start()` just created.
    private func openAudioFile(url: URL) throws {
        guard let tapFormat = usableTapFormat() else {
            throw CaptureError.tapCreationFailed(-2)
        }
        try openAudioFile(url: url, tapSampleRate: tapFormat.mSampleRate)
    }

    /// The tap's format, or nil when it cannot be read or its rate is not a
    /// positive finite number. Every buffer duration is computed from the
    /// rate, and the integer conversions of those durations trap on an
    /// infinite or NaN value.
    private func usableTapFormat() -> AudioStreamBasicDescription? {
        guard let format = tapHardware.format(self),
              format.mSampleRate.isFinite, format.mSampleRate > 0
        else { return nil }
        return format
    }

    /// Creates the ADTS AAC file and sets its client format once, before
    /// any write, to `SystemFormatConverter.clientFormat` — whatever the tap
    /// delivers. ExtAudioFile refuses a client format change after the
    /// first write (`-66565`, `kExtAudioFileError_InvalidOperationOrder`),
    /// so tap format changes are handled by converting each buffer instead.
    ///
    /// Internal so tests can write a real file without a tap.
    func openAudioFile(url: URL, tapSampleRate: Double) throws {
        self.tapSampleRate = tapSampleRate
        formatConverter = SystemFormatConverter()

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

        var clientASBD = SystemFormatConverter.clientFormat.streamDescription.pointee
        let clientStatus = ExtAudioFileSetProperty(
            file,
            kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
            &clientASBD
        )
        guard clientStatus == noErr else {
            ExtAudioFileDispose(file)
            throw CaptureError.tapCreationFailed(clientStatus)
        }

        let brStatus = EncoderSettings.applyBitRate(to: file, bitRate: encoder.bitRate)
        if brStatus != noErr {
            logger.warning("applyBitRate returned \(brStatus, privacy: .public) — using encoder default")
        }

        audioFile = file
    }

    /// Reads the tap's stream format (`kAudioTapPropertyFormat`), or nil
    /// if the query fails.
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
}

// MARK: - Hardware seam

extension LiveSystemCaptureEngine {
    /// The calls that need a real process tap. Production uses `live`; tests
    /// replace them to run `start()`, `reconnect()` and `stop()`, with the
    /// real writer thread and file, on a machine without a tap.
    struct TapHardware {
        /// Creates the process tap and its aggregate device.
        var create: @Sendable (LiveSystemCaptureEngine) throws -> Void
        /// Reads the tap's stream format, or nil if the query fails.
        var format: @Sendable (LiveSystemCaptureEngine) -> AudioStreamBasicDescription?
        /// Starts the IOProc that enqueues tap buffers into the ring buffer.
        var startIO: @Sendable (LiveSystemCaptureEngine, AudioRingBuffer) throws -> Void

        /// The Core Audio implementation.
        static let live = TapHardware(
            create: { try $0.createTapAndAggregate() },
            format: { $0.queryTapFormat() },
            startIO: { engine, _ in try engine.startIOProc() }
        )
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
