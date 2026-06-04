@preconcurrency import AVFoundation
import AudioToolbox
import Foundation

/// Microphone capture via a plain `AVAudioEngine` tap.
///
/// AVAudioEngine stops *itself* on an audio-route change (a call starting,
/// AirPods connecting, the default input device switching). The original code
/// never restarted, so the mic died at the first switch. This class observes
/// `AVAudioEngineConfigurationChange` and, on each change, re-queries the input
/// format fresh, reinstalls the tap (with a new converter if the source format
/// changed), and restarts the engine — keeping the same output file open. A
/// brief gap at the switch is acceptable.
final class MicCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let fileURL: URL

    /// Guards `extFile`, which is read by the tap callback (audio thread) and
    /// written by start/stop/reconfigure. Never held across file I/O.
    private let fileLock = NSLock()
    private var extFile: ExtAudioFileRef?

    private let lock = NSLock()
    private var _isCapturing = false

    /// Serializes configuration-change handling and teardown. The config-change
    /// notification fires on arbitrary threads and repeatedly per route change,
    /// so all reconfiguration runs here, debounced by `reconfigureGeneration`.
    private let configQueue = DispatchQueue(label: "com.audiolab.miccapture.config")
    private var configObserver: NSObjectProtocol?
    /// Touched only on `configQueue`. Bumped per notification; a scheduled
    /// reconfigure runs only if it is still the latest generation (debounce).
    private var reconfigureGeneration = 0
    /// Touched only on `configQueue`. Once true, no further reconfigures run.
    private var isTearingDown = false

    /// Invoked when mic capture hits an unrecoverable error (e.g. it cannot
    /// reconfigure after a route change). Called off the main thread; the
    /// handler is responsible for hopping to whatever isolation it needs.
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
        guard !_isCapturing else {
            lock.unlock()
            return
        }
        lock.unlock()

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // The tap always pre-converts to the encoder's processing format
        // (mono 24 kHz), so the ExtAudioFile client format must be THAT — not the
        // raw input (e.g. 3ch/48k) — or we'd write mono/16k buffers into a file
        // expecting 3ch/48k and the track comes out empty.
        let file = try Self.createExtAudioFile(
            url: fileURL,
            clientFormat: EncoderSettings.processingFormat
        )
        setExtFile(file)

        do {
            try installTap(inputFormat: inputFormat)
            engine.prepare()
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            closeExtFile()
            throw AudioLabError.micEngineStartFailed(error)
        }

        // Observe route changes. The engine has already stopped itself by the
        // time this fires; we just need to rebuild and restart.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }

        lock.lock()
        _isCapturing = true
        lock.unlock()
    }

    func stop() {
        lock.lock()
        guard _isCapturing else {
            lock.unlock()
            return
        }
        _isCapturing = false
        lock.unlock()

        // Remove the observer BEFORE syncing on configQueue. removeObserver
        // blocks until any in-flight notification block returns; if that block
        // were waiting on configQueue while we held it, we would deadlock.
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
            configObserver = nil
        }

        // Serialize against any in-flight reconfigure and block future ones.
        configQueue.sync {
            isTearingDown = true
            reconfigureGeneration += 1
        }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        closeExtFile()
    }

    deinit {
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        // No lock around _isCapturing here: deinit runs only when the last
        // reference is gone, so no other thread can be touching this instance.
        if _isCapturing {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        if let file = extFile {
            ExtAudioFileDispose(file)
        }
    }

    // MARK: - ExtAudioFile creation

    /// Creates an ADTS AAC ExtAudioFile and configures its client format and
    /// encoder bitrate. The client format is set to match the live tap so the
    /// converter handles any resampling/channel-mixing.
    private static func createExtAudioFile(
        url: URL,
        clientFormat: AVAudioFormat
    ) throws -> ExtAudioFileRef {
        var outputASBD = EncoderSettings.outputASBD()
        var fileRef: ExtAudioFileRef?
        let createStatus = ExtAudioFileCreateWithURL(
            url as CFURL,
            EncoderSettings.fileType,
            &outputASBD,
            nil,
            AudioFileFlags.eraseFile.rawValue,
            &fileRef
        )
        guard createStatus == noErr, let file = fileRef else {
            throw AudioLabError.failedToCreateAudioFile(createStatus)
        }

        // Set the client (input) format to the live PCM format. The internal
        // AudioConverter will resample + downmix as needed.
        var clientASBD = clientFormat.streamDescription.pointee
        let clientStatus = ExtAudioFileSetProperty(
            file,
            kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
            &clientASBD
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

        return file
    }

    // MARK: - Tap installation

    /// Installs a tap on the input bus for `inputFormat`, converting to the
    /// mono 24 kHz AAC output format. Writes go to the currently-open `extFile`,
    /// which stays the same across reconfigs.
    ///
    /// When the input format differs from the encoder's processing format
    /// (e.g. 3-channel 48 kHz from the M4 built-in mic), we use an
    /// AVAudioConverter to pre-convert to mono 24 kHz before handing to
    /// ExtAudioFile. This avoids "inconsistent packets" errors that occur when
    /// the ExtAudioFile internal converter must do large rate + channel changes.
    private func installTap(inputFormat: AVAudioFormat) throws {
        let targetFormat = EncoderSettings.processingFormat
        let inputNode = engine.inputNode

        let needsConversion =
            inputFormat.sampleRate != targetFormat.sampleRate ||
            inputFormat.channelCount != targetFormat.channelCount

        if needsConversion {
            guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
                throw NSError(
                    domain: "AudioLab", code: -1,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Cannot create audio converter for input format \(inputFormat)"]
                )
            }

            inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) {
                [weak self] buffer, _ in
                guard let self, let file = self.currentExtFile() else { return }

                let frameCapacity = AVAudioFrameCount(
                    Double(buffer.frameLength) * targetFormat.sampleRate / inputFormat.sampleRate
                )
                guard let convertedBuffer = AVAudioPCMBuffer(
                    pcmFormat: targetFormat, frameCapacity: frameCapacity
                ) else { return }

                var error: NSError?
                // The inputBlock is called synchronously within convert(), so
                // this flag is safe despite the @Sendable annotation on the block.
                nonisolated(unsafe) var hasProvidedData = false
                let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                    if hasProvidedData {
                        outStatus.pointee = .noDataNow
                        return nil
                    }
                    hasProvidedData = true
                    outStatus.pointee = .haveData
                    return buffer
                }
                converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)

                if error == nil, convertedBuffer.frameLength > 0 {
                    Self.writeBuffer(convertedBuffer, to: file)
                }
            }
        } else {
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) {
                [weak self] buffer, _ in
                guard let self, let file = self.currentExtFile() else { return }
                Self.writeBuffer(buffer, to: file)
            }
        }
    }

    /// Writes a PCM buffer to an ExtAudioFile. Logs errors without throwing
    /// (called from the audio tap callback).
    private static func writeBuffer(_ buffer: AVAudioPCMBuffer, to file: ExtAudioFileRef) {
        let bufferList = buffer.mutableAudioBufferList
        let status = ExtAudioFileWrite(file, buffer.frameLength, bufferList)
        if status != noErr {
            print("[MicCapture] ExtAudioFileWrite error: \(status)")
        }
    }

    // MARK: - Route-change handling

    private func handleConfigurationChange() {
        // Runs on an arbitrary thread; hand off to the serial queue immediately
        // so removeObserver in stop() never blocks on real work here.
        configQueue.async { [weak self] in
            guard let self else { return }
            guard !self.isTearingDown else { return }

            self.reconfigureGeneration += 1
            let generation = self.reconfigureGeneration

            // Debounce: a single route change emits several notifications in
            // quick succession. Only the last one within the window reconfigures.
            self.configQueue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self else { return }
                guard !self.isTearingDown else { return }
                guard generation == self.reconfigureGeneration else { return }
                self.reconfigure()
            }
        }
    }

    /// Must run on `configQueue`.
    private func reconfigure() {
        let inputNode = engine.inputNode

        // The engine has already stopped itself; make teardown explicit and
        // idempotent before rebuilding.
        inputNode.removeTap(onBus: 0)
        engine.stop()

        // Re-query the format FRESH every time — sample rate AND channel count
        // can both change. Reusing a stale format crashes or yields garbage.
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            // Transient invalid format mid-switch; a subsequent notification
            // will fire once the new device settles. Don't kill capture.
            print("[MicCapture] Skipping reconfigure: input format not ready \(inputFormat)")
            return
        }

        // Do NOT touch the ExtAudioFile client format here. It stays the encoder
        // processing format (mono 24 kHz) for the life of the file: installTap
        // below builds a fresh AVAudioConverter from the new input format to that
        // same processing format, so ExtAudioFile always receives mono 24 kHz
        // buffers regardless of the new device's format. Resetting the client
        // format to the raw input is exactly what produced the empty mic track.

        do {
            try installTap(inputFormat: inputFormat)
            engine.prepare()
            try engine.start()
        } catch {
            print("[MicCapture] Reconfigure failed: \(error)")
            onUnrecoverableError?(error)
            lock.lock()
            _isCapturing = false
            lock.unlock()
        }
    }

    // MARK: - Shared-state accessors

    private func setExtFile(_ file: ExtAudioFileRef?) {
        fileLock.lock()
        extFile = file
        fileLock.unlock()
    }

    private func closeExtFile() {
        // Detach under the lock, then dispose OUTSIDE it: ExtAudioFileDispose
        // flushes the encoder to disk (blocking I/O), and fileLock must never be
        // held across I/O (the real-time tap thread also takes it). Callers
        // already remove the tap first, but this keeps the invariant true.
        fileLock.lock()
        let file = extFile
        extFile = nil
        fileLock.unlock()
        if let file {
            ExtAudioFileDispose(file)
        }
    }

    private func currentExtFile() -> ExtAudioFileRef? {
        fileLock.lock()
        defer { fileLock.unlock() }
        return extFile
    }
}
