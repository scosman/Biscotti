// swiftlint:disable file_length
import AudioToolbox
import CoreAudio
import CoreMedia
import Foundation

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

    // Diagnostics (touched only on sampleQueue — no lock needed)
    private var hasLoggedSourceFormat = false
    private var framesWritten: Int64 = 0

    /// Called off the main thread on unrecoverable errors.
    var onUnrecoverableError: (@Sendable (Error) -> Void)?

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

        guard let device = MicCaptureDeviceResolver.systemDefaultInputDevice() else {
            setNotCapturing()
            throw AudioLabError.micSessionStartFailed(
                NSError(domain: "AudioLab", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "No audio capture device available"])
            )
        }
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            setNotCapturing()
            throw AudioLabError.micSessionStartFailed(error)
        }

        let file = try MicCaptureFileHelper.createExtAudioFile(
            url: fileURL, clientFormat: EncoderSettings.processingFormat
        )
        setExtFile(file)
        installDeviceChangeListener()
        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                try configureAndStartSession(input: input)
            } catch {
                print("[MicCapture] session start FAILED: \(error)")
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

        sampleQueue.async { [weak self] in
            guard let self else { return }
            print("[MicCapture] stopped — wrote \(framesWritten) frames")
        }

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
        }
    }

    deinit {
        if let observer = runtimeErrorObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        removeDeviceChangeListener()
        if _isCapturing { teardownSession() }
        if let file = extFile { ExtAudioFileDispose(file) }
    }

    /// Must run on `sessionQueue`.
    private func configureAndStartSession(input: AVCaptureDeviceInput) throws {
        let captureSession = AVCaptureSession()
        captureSession.beginConfiguration()
        guard captureSession.canAddInput(input) else {
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
            throw AudioLabError.micSessionStartFailed(
                NSError(domain: "AudioLab", code: -3,
                        userInfo: [NSLocalizedDescriptionKey: "Cannot add audio output"])
            )
        }
        captureSession.addOutput(output)
        captureSession.commitConfiguration()
        captureSession.startRunning()
        print("[MicCapture] startRunning; session.isRunning=\(captureSession.isRunning)")
        session = captureSession
        audioOutput = output
        sampleDelegate = delegate

        runtimeErrorObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionRuntimeError, object: captureSession, queue: nil
        ) { [weak self] notification in self?.handleRuntimeError(notification) }
    }

    private func teardownSession() {
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
        guard let file = currentExtFile() else { return }
        guard let pcmBuffer = MicCaptureFileHelper.pcmBuffer(from: sampleBuffer) else { return }

        let targetFormat = EncoderSettings.processingFormat
        let sourceFormat = pcmBuffer.format

        if !hasLoggedSourceFormat {
            hasLoggedSourceFormat = true
            print("[MicCapture] source format: \(sourceFormat.sampleRate) Hz, " +
                "\(sourceFormat.channelCount) ch, interleaved=\(sourceFormat.isInterleaved)")
        }

        let written: AVAudioPCMBuffer
        if sourceFormat.sampleRate == targetFormat.sampleRate,
           sourceFormat.channelCount == targetFormat.channelCount
        {
            MicCaptureFileHelper.writeBuffer(pcmBuffer, to: file)
            written = pcmBuffer
        } else {
            guard let converter = converterForSource(sourceFormat),
                  let converted = MicCaptureFileHelper.convert(
                      pcmBuffer, to: targetFormat, using: converter
                  )
            else { return }
            MicCaptureFileHelper.writeBuffer(converted, to: file)
            written = converted
        }
        framesWritten += Int64(written.frameLength)
    }

    private func converterForSource(_ sourceFormat: AVAudioFormat) -> AVAudioConverter? {
        let sourceHash = sourceFormat.hash
        if sourceHash == cachedConverterSourceHash, let converter = cachedConverter {
            return converter
        }
        let targetFormat = EncoderSettings.processingFormat
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            return nil
        }
        cachedConverter = converter
        cachedConverterSourceHash = sourceHash
        return converter
    }

    private func handleRuntimeError(_ notification: Notification) {
        guard let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError else {
            return
        }
        sessionQueue.async { [weak self] in
            guard let self, !isTearingDown else { return }
            reconfigure(reason: error)
        }
    }

    fileprivate func handleDeviceChange() {
        sessionQueue.async { [weak self] in
            guard let self, !isTearingDown else { return }
            reconfigure(reason: nil)
        }
    }

    private func reconfigure(reason: Error?) {
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
            let input = try AVCaptureDeviceInput(device: device)
            try configureAndStartSession(input: input)
        } catch {
            print("[MicCapture] Reconfigure failed: \(reason ?? error)")
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

private enum MicCaptureFileHelper {
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
    /// audio (e.g. 3ch / 48 kHz on Apple-silicon built-in mic).
    static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let sourceASBD = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc),
              let sourceFormat = AVAudioFormat(streamDescription: sourceASBD)
        else { return nil }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat,
                                            frameCapacity: AVAudioFrameCount(frameCount))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: buffer.mutableAudioBufferList
        )
        guard status == noErr else {
            print("[MicCapture] CMSampleBufferCopyPCMDataIntoAudioBufferList error: \(status)")
            return nil
        }
        return buffer
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
        guard error == nil, output.frameLength > 0 else { return nil }
        return output
    }

    static func writeBuffer(_ buffer: AVAudioPCMBuffer, to file: ExtAudioFileRef) {
        let status = ExtAudioFileWrite(file, buffer.frameLength, buffer.mutableAudioBufferList)
        if status != noErr {
            print("[MicCapture] ExtAudioFileWrite error: \(status)")
        }
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
        guard let deviceID: AudioDeviceID = CoreAudioHelpers.getPropertyData(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            address: AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            type: AudioDeviceID.self
        ), deviceID != kAudioObjectUnknown else {
            print("[MicCapture] could not get default input device ID; falling back")
            return fallbackDevice()
        }

        // Step 2: get the UID string for that device.
        guard let uid = CoreAudioHelpers.deviceUID(for: deviceID) else {
            print("[MicCapture] could not get UID for device \(deviceID); falling back")
            return fallbackDevice()
        }

        // Step 3: resolve to AVCaptureDevice via uniqueID.
        if let device = AVCaptureDevice(uniqueID: uid) {
            let name = device.localizedName, id = device.uniqueID
            print("[MicCapture] using input device: \(name) [\(id)] (source: systemDefaultUID)")
            return device
        }

        // UID valid in Core Audio but not in AVCaptureDevice — fall back.
        print("[MicCapture] AVCaptureDevice not found for UID '\(uid)'; falling back")
        return fallbackDevice()
    }

    private static func fallbackDevice() -> AVCaptureDevice? {
        let device = AVCaptureDevice.default(for: .audio)
        if let device {
            print("[MicCapture] using input device: \(device.localizedName) [\(device.uniqueID)] (source: fallback)")
        }
        return device
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
