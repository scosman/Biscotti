// swiftlint:disable file_length type_body_length
import AudioToolbox
import CoreAudio
import CoreMedia
import Foundation
import os

@preconcurrency import AVFoundation

/// Microphone capture via `AVCaptureSession` + `AVCaptureAudioDataOutput`.
///
/// Session lifecycle (`startRunning`/`stopRunning`/configure) runs on a
/// dedicated serial `sessionQueue` so blocking HAL calls stay off the main
/// thread. `start()` pre-flights device availability synchronously then
/// dispatches the session start; async failures surface via
/// `onUnrecoverableError`. Route/error changes rebuild the session on the
/// same queue, keeping the output file open. Samples are converted to mono
/// 24 kHz and written as ADTS AAC via `ExtAudioFile`.
///
/// Diagnostics: every lifecycle event is logged to `Log.mic`. A 2 s heartbeat
/// (`heartbeat()`) summarises buffer/frame counters and fires watchdog faults
/// when the mic never starts, stalls after starting, or delivers buffers that
/// never reach disk (extraction/conversion/write failures). See `Log` in
/// `CoreAudioHelpers.swift`.
final class MicCapture: @unchecked Sendable {
    private let fileURL: URL

    private let fileLock = NSLock() // guards extFile
    private var extFile: ExtAudioFileRef?
    private let lock = NSLock()
    private var _isCapturing = false

    /// Session lifecycle queue (configure / start / stop). Off main thread.
    private let sessionQueue = DispatchQueue(label: "com.audiolab.miccapture.session")
    private var isTearingDown = false
    private var session: AVCaptureSession?
    private var audioOutput: AVCaptureAudioDataOutput?
    private let sampleQueue = DispatchQueue(label: "com.audiolab.miccapture.samples")
    private var sampleDelegate: SampleBufferDelegate?
    private var cachedConverter: AVAudioConverter? // keyed by source format hash
    private var cachedConverterSourceHash: Int = 0
    private var runtimeErrorObserver: NSObjectProtocol?
    private var hasDeviceChangeListener = false

    // MARK: - Diagnostics

    /// Counters describing the sample pipeline. Mutated on `sampleQueue`,
    /// snapshotted on the heartbeat queue — guarded by `statsLock`.
    private struct Stats {
        var buffersReceived = 0
        var framesWritten = 0
        var extractFailures = 0
        var convertFailures = 0
        var writeFailures = 0
        var lastSourceFormat = "?"
        /// Peak |sample| of the written (mono) audio over the current heartbeat
        /// window. ~0 with frames climbing ⇒ we're capturing silence (e.g. a
        /// muted second client on a voice-processing-held device).
        var outputPeak: Float = 0
        /// Per-source-channel peak |sample| over the current heartbeat window.
        /// Reveals whether only one array channel carries the voice (so the
        /// averaging downmix is attenuating the level by the channel count).
        var channelPeaks: [Float] = []
    }

    private let statsLock = NSLock()
    private var stats = Stats()

    private let heartbeatQueue = DispatchQueue(label: "com.audiolab.miccapture.heartbeat")
    private var heartbeatTimer: DispatchSourceTimer?
    // Heartbeat-queue-only state.
    private var heartbeatTick = 0
    private var lastBuffersReceived = 0
    private var stallReported = false
    private var writeStallReported = false

    private static let heartbeatInterval = 2

    /// Called off the main thread on unrecoverable errors.
    var onUnrecoverableError: (@Sendable (Error) -> Void)?

    /// Called off the main thread exactly once, when the first sample buffer is
    /// delivered (proof the mic's input IO is live). The argument is the host-
    /// clock time in seconds of that first frame (its presentation timestamp) —
    /// the recording's t=0. Used to start system capture only after the mic is
    /// genuinely running, and to align the two tracks.
    var onStarted: (@Sendable (Double) -> Void)?
    private var didNotifyStarted = false // guarded by `lock`

    var isCapturing: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isCapturing
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func start() throws {
        lock.lock()
        guard !_isCapturing else { lock.unlock(); return }
        _isCapturing = true
        lock.unlock()

        Log.mic.event("start() requested → file=\(fileURL.lastPathComponent)")
        Log.mic.event("input state at start: \(CoreAudioHelpers.inputDiagnosticsSnapshot())")

        guard let device = MicCaptureDeviceResolver.systemDefaultInputDevice() else {
            Log.mic.err("start() ABORTED: no audio capture device available")
            setNotCapturing()
            throw AudioLabError.micSessionStartFailed(
                NSError(domain: "AudioLab", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "No audio capture device available"])
            )
        }
        Log.mic.event("resolved capture device: \"\(device.localizedName)\" uid=\(device.uniqueID)")

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            Log.mic.err("start() ABORTED: AVCaptureDeviceInput init failed: \(error.localizedDescription)")
            setNotCapturing()
            throw AudioLabError.micSessionStartFailed(error)
        }

        let file = try MicCaptureFileHelper.createExtAudioFile(
            url: fileURL, clientFormat: EncoderSettings.processingFormat
        )
        setExtFile(file)
        Log.mic.event("created ExtAudioFile (client \(EncoderSettings.describe(EncoderSettings.processingFormat)))")
        installDeviceChangeListener()
        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                try configureAndStartSession(input: input)
            } catch {
                Log.mic.err("configureAndStartSession threw: \(error.localizedDescription)")
                closeExtFile()
                setNotCapturing()
                onUnrecoverableError?(error)
            }
        }
    }

    func stop() {
        lock.lock()
        guard _isCapturing else { lock.unlock(); return }
        _isCapturing = false
        lock.unlock()

        Log.mic.event("stop() requested")
        removeDeviceChangeListener()
        sessionQueue.async { [weak self] in
            guard let self else { return }
            isTearingDown = true
            if let observer = runtimeErrorObserver {
                NotificationCenter.default.removeObserver(observer)
                runtimeErrorObserver = nil
            }
            teardownSession()
            closeExtFile()
            let snap = snapshotStats()
            Log.mic.event(
                "stopped. totals: buffers=\(snap.buffersReceived) framesWritten=\(snap.framesWritten) " +
                    "extractFail=\(snap.extractFailures) convertFail=\(snap.convertFailures) " +
                    "writeFail=\(snap.writeFailures)"
            )
        }
    }

    deinit {
        if let observer = runtimeErrorObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        removeDeviceChangeListener()
        heartbeatTimer?.cancel()
        if _isCapturing { teardownSession() }
        if let file = extFile { ExtAudioFileDispose(file) }
    }

    /// Must run on `sessionQueue`.
    private func configureAndStartSession(input: AVCaptureDeviceInput) throws {
        Log.mic.event("configuring AVCaptureSession on \"\(input.device.localizedName)\"")
        logActiveDeviceFormat(input.device)

        let captureSession = AVCaptureSession()
        captureSession.beginConfiguration()
        guard captureSession.canAddInput(input) else {
            captureSession.commitConfiguration()
            Log.mic.err("cannot add audio input to session")
            throw AudioLabError.micSessionStartFailed(
                NSError(domain: "AudioLab", code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "Cannot add audio input"])
            )
        }
        captureSession.addInput(input)
        let output = AVCaptureAudioDataOutput()
        // Deliver the mic's native format (nil = no internal conversion).
        // CMIO's internal converter fails to resample/downmix when we're
        // the sole audio client (→ zero-byte file). Our processSampleBuffer
        // already converts any source format to mono 24 kHz via AVAudioConverter.
        output.audioSettings = nil
        let delegate = SampleBufferDelegate(micCapture: self)
        output.setSampleBufferDelegate(delegate, queue: sampleQueue)
        guard captureSession.canAddOutput(output) else {
            captureSession.commitConfiguration()
            Log.mic.err("cannot add audio output to session")
            throw AudioLabError.micSessionStartFailed(
                NSError(domain: "AudioLab", code: -3,
                        userInfo: [NSLocalizedDescriptionKey: "Cannot add audio output"])
            )
        }
        captureSession.addOutput(output)
        captureSession.commitConfiguration()
        Log.mic.event("committed configuration; calling startRunning()…")
        captureSession.startRunning()
        session = captureSession
        audioOutput = output
        sampleDelegate = delegate
        Log.mic.event("startRunning() returned — session.isRunning=\(captureSession.isRunning)")

        startHeartbeat()

        runtimeErrorObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionRuntimeError, object: captureSession, queue: nil
        ) { [weak self] notification in self?.handleRuntimeError(notification) }
    }

    private func logActiveDeviceFormat(_ device: AVCaptureDevice) {
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(
            device.activeFormat.formatDescription
        )?.pointee else {
            Log.mic.event("device active format: <unavailable>")
            return
        }
        Log.mic.event("device active format: \(Int(asbd.mSampleRate))Hz \(asbd.mChannelsPerFrame)ch")
    }

    private func teardownSession() {
        Log.mic.event("teardownSession()")
        stopHeartbeat()
        session?.stopRunning()
        session = nil
        audioOutput = nil
        sampleDelegate = nil
        cachedConverter = nil
        cachedConverterSourceHash = 0
    }

    private func setNotCapturing() {
        lock.lock(); _isCapturing = false; lock.unlock()
    }

    fileprivate func processSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        notifyStartedIfNeeded(sampleBuffer)
        mutateStats { $0.buffersReceived += 1 }

        guard let file = currentExtFile() else { return }
        guard let pcmBuffer = MicCaptureFileHelper.pcmBuffer(from: sampleBuffer) else {
            mutateStats { $0.extractFailures += 1 }
            return
        }

        // Log per-channel input levels the first time we see a format (and on any
        // format change). This tells us whether the raw mic channels actually
        // carry signal — the deciding test for "muted second client" vs. a
        // downmix bug.
        if recordSourceFormatIfChanged(pcmBuffer.format) {
            logChannelPeaks(pcmBuffer)
        }

        // Track per-channel input levels every buffer so the heartbeat can show
        // live levels during speech (the one-shot log above lands at t=0 silence).
        let srcPeaks = MicCaptureFileHelper.channelPeaks(of: pcmBuffer)
        mutateStats { stats in
            if stats.channelPeaks.count == srcPeaks.count {
                for index in srcPeaks.indices {
                    stats.channelPeaks[index] = max(stats.channelPeaks[index], srcPeaks[index])
                }
            } else {
                stats.channelPeaks = srcPeaks
            }
        }

        // Downmix to mono ourselves rather than letting AVAudioConverter do it:
        // the built-in mic's multichannel stream uses a *discrete* layout, which
        // AVAudioConverter maps to silence (no error) when reducing to mono. We
        // average the channels at the source rate, then only resample mono→mono.
        guard let mono = MicCaptureFileHelper.downmixToMono(pcmBuffer) else {
            mutateStats { $0.convertFailures += 1 }
            return
        }

        let targetFormat = EncoderSettings.processingFormat
        let bufferToWrite: AVAudioPCMBuffer
        if mono.format.sampleRate == targetFormat.sampleRate {
            bufferToWrite = mono
        } else {
            guard let converter = converterForSource(mono.format),
                  let converted = MicCaptureFileHelper.convert(
                      mono, to: targetFormat, using: converter
                  )
            else {
                mutateStats { $0.convertFailures += 1 }
                return
            }
            bufferToWrite = converted
        }

        let outPeak = MicCaptureFileHelper.peak(of: bufferToWrite)
        let status = MicCaptureFileHelper.writeBuffer(bufferToWrite, to: file)
        if status == noErr {
            mutateStats {
                $0.framesWritten += Int(bufferToWrite.frameLength)
                $0.outputPeak = max($0.outputPeak, outPeak)
            }
        } else {
            mutateStats { $0.writeFailures += 1 }
        }
    }

    /// Logs the peak |sample| of each raw source channel once per format. If all
    /// channels read ~0 while the device claims to be running, we're receiving a
    /// silent stream (the voice-processing-contention failure), not just a bad
    /// downmix.
    private func logChannelPeaks(_ buffer: AVAudioPCMBuffer) {
        let peaks = MicCaptureFileHelper.channelPeaks(of: buffer)
        let desc = peaks.enumerated()
            .map { "ch\($0.offset)=\(String(format: "%.4f", $0.element))" }
            .joined(separator: " ")
        Log.mic.event("source channel peaks: \(desc) (frames=\(buffer.frameLength))")
    }

    /// Fires `onStarted` exactly once, with the host-clock time (seconds) of the
    /// first sample's presentation timestamp. Falls back to 0 if the timestamp
    /// is invalid (alignment padding is then skipped, but capture still starts).
    private func notifyStartedIfNeeded(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        if didNotifyStarted { lock.unlock(); return }
        didNotifyStarted = true
        lock.unlock()

        let seconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        let anchor = seconds.isFinite ? seconds : 0
        let fmtDesc = CMSampleBufferGetFormatDescription(sampleBuffer)
            .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
            .map { "\(Int($0.mSampleRate))Hz \($0.mChannelsPerFrame)ch" } ?? "?"
        Log.mic.event("FIRST mic sample delivered — anchor=\(anchor)s src=\(fmtDesc). Mic IO is live.")
        onStarted?(anchor)
    }

    @discardableResult
    private func recordSourceFormatIfChanged(_ format: AVAudioFormat) -> Bool {
        let desc = EncoderSettings.describe(format)
        let changed = mutateStats { stats -> Bool in
            guard stats.lastSourceFormat != desc else { return false }
            stats.lastSourceFormat = desc
            return true
        }
        if changed {
            Log.mic.event("mic source format: \(desc)")
        }
        return changed
    }

    private func converterForSource(_ sourceFormat: AVAudioFormat) -> AVAudioConverter? {
        let sourceHash = sourceFormat.hash
        if sourceHash == cachedConverterSourceHash, let converter = cachedConverter {
            return converter
        }
        let targetFormat = EncoderSettings.processingFormat
        let sourceDesc = EncoderSettings.describe(sourceFormat)
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            Log.mic.err("failed to build AVAudioConverter from \(sourceDesc)")
            return nil
        }
        Log.mic.event("built converter \(sourceDesc) → \(EncoderSettings.describe(targetFormat))")
        cachedConverter = converter
        cachedConverterSourceHash = sourceHash
        return converter
    }

    private func handleRuntimeError(_ notification: Notification) {
        let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError
        Log.mic.err("AVCaptureSessionRuntimeError: \(error.map { "\($0)" } ?? "<unknown>")")
        guard let error else { return }
        sessionQueue.async { [weak self] in
            guard let self, !isTearingDown else { return }
            reconfigure(reason: error)
        }
    }

    fileprivate func handleDeviceChange() {
        Log.device.event("default input device changed → rebuilding mic session")
        Log.device.event("new input state: \(CoreAudioHelpers.inputDiagnosticsSnapshot())")
        sessionQueue.async { [weak self] in
            guard let self, !isTearingDown else { return }
            reconfigure(reason: nil)
        }
    }

    private func reconfigure(reason: Error?) {
        Log.mic.event("reconfigure() start (reason: \(reason.map { $0.localizedDescription } ?? "device change"))")
        if let observer = runtimeErrorObserver {
            NotificationCenter.default.removeObserver(observer)
            runtimeErrorObserver = nil
        }
        teardownSession()
        do {
            guard let device = MicCaptureDeviceResolver.systemDefaultInputDevice() else {
                throw AudioLabError.micSessionStartFailed(
                    NSError(domain: "AudioLab", code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "No audio device"])
                )
            }
            Log.mic.event("reconfigure: rebinding to \"\(device.localizedName)\"")
            let input = try AVCaptureDeviceInput(device: device)
            try configureAndStartSession(input: input)
            Log.mic.event("reconfigure: session restarted")
        } catch {
            Log.mic.err("reconfigure FAILED: \((reason ?? error).localizedDescription)")
            onUnrecoverableError?(reason ?? error)
            setNotCapturing()
        }
    }

    private func installDeviceChangeListener() {
        var address = MicCaptureDeviceListener.propertyAddress
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let status = AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject), &address,
            MicCaptureDeviceListener.callback, selfPtr
        )
        hasDeviceChangeListener = (status == noErr)
        if status == noErr {
            Log.device.event("installed default-input-device change listener")
        } else {
            Log.device.err("failed to install default-input-device listener: \(osStatusString(status))")
        }
    }

    private func removeDeviceChangeListener() {
        guard hasDeviceChangeListener else { return }
        var address = MicCaptureDeviceListener.propertyAddress
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        AudioObjectRemovePropertyListener(
            AudioObjectID(kAudioObjectSystemObject), &address,
            MicCaptureDeviceListener.callback, selfPtr
        )
        hasDeviceChangeListener = false
    }

    // MARK: - Heartbeat / watchdog

    /// Starts the 2 s diagnostic heartbeat and resets per-session counters.
    /// Runs on `sessionQueue` (from configure / reconfigure).
    private func startHeartbeat() {
        stopHeartbeat()
        mutateStats { $0 = Stats() }
        heartbeatQueue.sync {
            heartbeatTick = 0
            lastBuffersReceived = 0
            stallReported = false
            writeStallReported = false
        }
        let timer = DispatchSource.makeTimerSource(queue: heartbeatQueue)
        timer.schedule(
            deadline: .now() + .seconds(Self.heartbeatInterval),
            repeating: .seconds(Self.heartbeatInterval)
        )
        timer.setEventHandler { [weak self] in self?.heartbeat() }
        heartbeatTimer = timer
        timer.resume()
        Log.mic.event("heartbeat started (\(Self.heartbeatInterval)s interval)")
    }

    private func stopHeartbeat() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
    }

    /// Runs on `heartbeatQueue`. Logs a counter summary and raises watchdog
    /// faults for the three failure shapes we care about: (1) the mic never
    /// delivers a buffer, (2) it delivers some then stalls, (3) buffers arrive
    /// but none reach disk.
    private func heartbeat() {
        heartbeatTick += 1
        let elapsed = heartbeatTick * Self.heartbeatInterval
        // Snapshot and reset the peak windows atomically.
        let snap = mutateStats { stats -> Stats in
            let copy = stats
            stats.outputPeak = 0
            stats.channelPeaks = []
            return copy
        }
        let delta = snap.buffersReceived - lastBuffersReceived
        lastBuffersReceived = snap.buffersReceived

        Log.mic.event(
            "heartbeat t≈\(elapsed)s buffers=\(snap.buffersReceived)(+\(delta)) " +
                "framesWritten=\(snap.framesWritten) outPeak=\(String(format: "%.4f", snap.outputPeak)) " +
                "extractFail=\(snap.extractFailures) convertFail=\(snap.convertFailures) " +
                "writeFail=\(snap.writeFailures) src=[\(snap.lastSourceFormat)]"
        )

        let chDesc = snap.channelPeaks.isEmpty
            ? "n/a"
            : snap.channelPeaks.enumerated()
            .map { "ch\($0.offset)=\(String(format: "%.4f", $0.element))" }
            .joined(separator: " ")
        Log.mic.event("heartbeat src channel peaks: \(chDesc)")

        let flowing = delta > 0
        if flowing {
            stallReported = false
        } else if !stallReported {
            stallReported = true
            if snap.buffersReceived == 0 {
                Log.mic.err(
                    "WATCHDOG: NO mic buffers \(elapsed)s after start — input IO never serviced " +
                        "(mic file will stay empty)."
                )
            } else {
                Log.mic.err(
                    "WATCHDOG: mic STALLED after \(snap.buffersReceived) buffers — none in last " +
                        "\(Self.heartbeatInterval)s."
                )
            }
            Log.mic.err("WATCHDOG input state: \(CoreAudioHelpers.inputDiagnosticsSnapshot())")
        }

        if snap.buffersReceived > 0, snap.framesWritten == 0, !writeStallReported {
            writeStallReported = true
            Log.mic.err(
                "WATCHDOG: \(snap.buffersReceived) buffers received but 0 frames written — " +
                    "extraction/convert/write failing for this mic format (\(snap.lastSourceFormat))."
            )
        }
    }

    // MARK: - Stats helpers

    @discardableResult
    private func mutateStats<T>(_ body: (inout Stats) -> T) -> T {
        statsLock.lock()
        defer { statsLock.unlock() }
        return body(&stats)
    }

    private func snapshotStats() -> Stats {
        statsLock.lock()
        defer { statsLock.unlock() }
        return stats
    }

    // MARK: - File handle

    private func setExtFile(_ file: ExtAudioFileRef?) {
        fileLock.lock(); extFile = file; fileLock.unlock()
    }

    private func closeExtFile() {
        fileLock.lock()
        let file = extFile
        extFile = nil
        fileLock.unlock()
        if let file { ExtAudioFileDispose(file) }
    }

    fileprivate func currentExtFile() -> ExtAudioFileRef? {
        fileLock.lock()
        defer { fileLock.unlock() }
        return extFile
    }
}

/// Shared ExtAudioFile + buffer helpers for both mic-capture paths
/// (`MicCapture`, the AVCaptureSession path, and `VPIOMicCapture`, the
/// VoiceProcessingIO path). Internal (not `private`) so `VPIOMicCapture` can
/// reuse the file creation, conversion, peak and write routines unchanged.
enum MicCaptureFileHelper {
    static func createExtAudioFile(url: URL, clientFormat: AVAudioFormat) throws -> ExtAudioFileRef {
        var outputASBD = EncoderSettings.outputASBD()
        var fileRef: ExtAudioFileRef?
        let createStatus = ExtAudioFileCreateWithURL(
            url as CFURL, EncoderSettings.fileType, &outputASBD, nil,
            AudioFileFlags.eraseFile.rawValue, &fileRef
        )
        guard createStatus == noErr, let file = fileRef else {
            throw AudioLabError.failedToCreateAudioFile(createStatus)
        }
        var clientASBD = clientFormat.streamDescription.pointee
        let clientStatus = ExtAudioFileSetProperty(
            file, kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &clientASBD
        )
        guard clientStatus == noErr else {
            ExtAudioFileDispose(file)
            throw AudioLabError.failedToSetClientFormat(clientStatus)
        }
        let brStatus = EncoderSettings.applyBitRate(to: file)
        guard brStatus == noErr else {
            ExtAudioFileDispose(file)
            throw AudioLabError.failedToSetEncoderBitRate(brStatus)
        }
        return file
    }

    /// Copies PCM data from a `CMSampleBuffer` into an `AVAudioPCMBuffer`
    /// allocated in the source format. Handles multichannel non-interleaved
    /// audio (e.g. 3ch / 44.1 kHz on the Apple-silicon built-in beamforming mic).
    static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let sourceASBD = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
        else {
            Log.mic.err("pcmBuffer: no stream basic description on sample buffer")
            return nil
        }
        guard let sourceFormat = audioFormat(from: formatDesc, asbd: sourceASBD) else {
            Log.mic.err("pcmBuffer: could not build AVAudioFormat (\(sourceASBD.pointee.mChannelsPerFrame)ch)")
            return nil
        }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat,
                                            frameCapacity: AVAudioFrameCount(frameCount))
        else {
            Log.mic.err("pcmBuffer: could not allocate buffer (frameCount=\(frameCount))")
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: buffer.mutableAudioBufferList
        )
        guard status == noErr else {
            Log.mic.err("pcmBuffer: CMSampleBufferCopyPCMDataIntoAudioBufferList error \(osStatusString(status))")
            return nil
        }
        return buffer
    }

    /// Builds an `AVAudioFormat` for a sample buffer.
    ///
    /// The plain `AVAudioFormat(streamDescription:)` initializer returns nil for
    /// any PCM format with **more than two channels** unless a channel layout is
    /// supplied. The Apple-silicon built-in mic is a 3-channel beamforming array
    /// — and it stays in 3ch mode when a voice-processing app (FaceTime, browser
    /// meetings via `com.apple.WebKit.GPU`) already had the mic open — so the
    /// plain initializer fails and every buffer is dropped (empty mic file). We
    /// attach the layout carried by the format description, falling back to a
    /// discrete N-channel layout.
    static func audioFormat(
        from formatDesc: CMAudioFormatDescription,
        asbd: UnsafePointer<AudioStreamBasicDescription>
    ) -> AVAudioFormat? {
        if let format = AVAudioFormat(streamDescription: asbd) {
            return format
        }
        var layoutSize = 0
        if let layoutPtr = CMAudioFormatDescriptionGetChannelLayout(formatDesc, sizeOut: &layoutSize) {
            let layout = AVAudioChannelLayout(layout: layoutPtr)
            return AVAudioFormat(streamDescription: asbd, channelLayout: layout)
        }
        if let layout = AVAudioChannelLayout(
            layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | asbd.pointee.mChannelsPerFrame
        ) {
            return AVAudioFormat(streamDescription: asbd, channelLayout: layout)
        }
        return nil
    }

    /// Downmixes a (possibly multichannel, non-interleaved float) PCM buffer to
    /// a single mono channel at the **same sample rate**, by averaging channels.
    ///
    /// We do this explicitly instead of letting `AVAudioConverter` reduce the
    /// channel count: the built-in mic exposes a *discrete* multichannel layout,
    /// which the converter maps to silence (returning no error). Averaging keeps
    /// whatever signal the array carries. The mono result is then resampled
    /// (mono→mono) by the caller.
    static func downmixToMono(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let channels = Int(source.format.channelCount)
        let frames = Int(source.frameLength)
        guard frames > 0, let srcData = source.floatChannelData else { return nil }

        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: source.format.sampleRate,
            channels: 1,
            interleaved: false
        ), let mono = AVAudioPCMBuffer(pcmFormat: monoFormat,
                                       frameCapacity: AVAudioFrameCount(frames))
        else { return nil }
        mono.frameLength = AVAudioFrameCount(frames)
        guard let dst = mono.floatChannelData?[0] else { return nil }

        if channels <= 1 {
            dst.update(from: srcData[0], count: frames)
            return mono
        }

        let scale = 1.0 / Float(channels)
        for frame in 0 ..< frames {
            var sum: Float = 0
            for channel in 0 ..< channels {
                sum += srcData[channel][frame]
            }
            dst[frame] = sum * scale
        }
        return mono
    }

    /// Extracts **channel 0** of a (possibly multichannel, non-interleaved
    /// float) PCM buffer into a mono buffer at the **same sample rate** — used
    /// by the VPIO path.
    ///
    /// With VoiceProcessingIO the processed/beamformed/echo-cancelled mono lives
    /// on **channel 0**; the remaining channels (VPIO silently presents ~9) are
    /// raw-array / reference feeds. So unlike the AVCaptureSession path — which
    /// *averages* the raw beamformer capsules (`downmixToMono`) — we take ch0
    /// verbatim; averaging the reference channels back in would dilute the
    /// processed signal with the very raw, quiet audio VPIO exists to replace.
    /// Do **not** use `AVAudioConverter` for this reduction: it maps the discrete
    /// multichannel layout to silence (no error), the same trap `downmixToMono`
    /// documents.
    static func extractChannel0(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let frames = Int(source.frameLength)
        guard frames > 0, let srcData = source.floatChannelData else { return nil }

        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: source.format.sampleRate,
            channels: 1,
            interleaved: false
        ), let mono = AVAudioPCMBuffer(pcmFormat: monoFormat,
                                       frameCapacity: AVAudioFrameCount(frames))
        else { return nil }
        mono.frameLength = AVAudioFrameCount(frames)
        guard let dst = mono.floatChannelData?[0] else { return nil }
        dst.update(from: srcData[0], count: frames)
        return mono
    }

    /// Peak |sample| of each channel (non-interleaved float).
    static func channelPeaks(of buffer: AVAudioPCMBuffer) -> [Float] {
        guard let data = buffer.floatChannelData else { return [] }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        return (0 ..< channels).map { channel in
            let ptr = data[channel]
            var peak: Float = 0
            for frame in 0 ..< frames {
                let value = abs(ptr[frame])
                if value > peak { peak = value }
            }
            return peak
        }
    }

    /// Peak |sample| across all channels of a buffer.
    static func peak(of buffer: AVAudioPCMBuffer) -> Float {
        channelPeaks(of: buffer).max() ?? 0
    }

    /// Converts a PCM buffer to `targetFormat` via the supplied converter.
    static func convert(
        _ source: AVAudioPCMBuffer,
        to targetFormat: AVAudioFormat,
        using converter: AVAudioConverter
    ) -> AVAudioPCMBuffer? {
        let frameCapacity = AVAudioFrameCount(
            Double(source.frameLength) * targetFormat.sampleRate / source.format.sampleRate
        )
        guard frameCapacity > 0,
              let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity)
        else { return nil }

        var error: NSError?
        nonisolated(unsafe) var hasProvidedData = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if hasProvidedData { outStatus.pointee = .noDataNow; return nil }
            hasProvidedData = true
            outStatus.pointee = .haveData
            return source
        }
        converter.convert(to: output, error: &error, withInputFrom: inputBlock)
        if let error {
            Log.mic.err("convert: AVAudioConverter error \(error.localizedDescription)")
            return nil
        }
        guard output.frameLength > 0 else { return nil }
        return output
    }

    @discardableResult
    static func writeBuffer(_ buffer: AVAudioPCMBuffer, to file: ExtAudioFileRef) -> OSStatus {
        let status = ExtAudioFileWrite(file, buffer.frameLength, buffer.mutableAudioBufferList)
        if status != noErr {
            Log.mic.err("ExtAudioFileWrite error \(osStatusString(status))")
        }
        return status
    }
}

private final class SampleBufferDelegate: NSObject,
    AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable
{
    private weak var micCapture: MicCapture?

    init(micCapture: MicCapture) {
        self.micCapture = micCapture
    }

    func captureOutput(
        _: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from _: AVCaptureConnection
    ) {
        micCapture?.processSampleBuffer(sampleBuffer)
    }
}

/// Resolves the system default input device as an `AVCaptureDevice`.
///
/// `AVCaptureDevice.default(for: .audio)` can bind a Continuity/iPhone
/// device that only delivers audio when another app is actively using it.
/// Core Audio's `kAudioHardwarePropertyDefaultInputDevice` returns the
/// real system default — the same device AVAudioEngine would use.
///
/// Falls back to `AVCaptureDevice.default(for: .audio)` if any Core Audio
/// step fails.
private enum MicCaptureDeviceResolver {
    static func systemDefaultInputDevice() -> AVCaptureDevice? {
        // Step 1: get the default input AudioDeviceID from the HAL.
        guard let deviceID = CoreAudioHelpers.defaultInputDeviceID(),
              deviceID != kAudioObjectUnknown
        else {
            Log.device.warn("resolver: no HAL default input device — falling back to AVCaptureDevice.default")
            return fallbackDevice()
        }

        // Step 2: get the UID string for that device.
        guard let uid = CoreAudioHelpers.deviceUID(for: deviceID) else {
            Log.device.warn("resolver: HAL device \(deviceID) has no UID — falling back")
            return fallbackDevice()
        }

        // Step 3: resolve to AVCaptureDevice via uniqueID.
        if let device = AVCaptureDevice(uniqueID: uid) {
            return device
        }

        // UID valid in Core Audio but not in AVCaptureDevice — fall back.
        Log.device.warn("resolver: UID \(uid) not an AVCaptureDevice — falling back")
        return fallbackDevice()
    }

    private static func fallbackDevice() -> AVCaptureDevice? {
        AVCaptureDevice.default(for: .audio)
    }
}

private enum MicCaptureDeviceListener {
    static var propertyAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static let callback: AudioObjectPropertyListenerProc = { _, _, _, clientData in
        guard let clientData else { return noErr }
        let mic = Unmanaged<MicCapture>.fromOpaque(clientData).takeUnretainedValue()
        mic.handleDeviceChange()
        return noErr
    }
}
