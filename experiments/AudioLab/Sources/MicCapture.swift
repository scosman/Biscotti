@preconcurrency import AVFoundation
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

    /// Guards `audioFile`, which is read by the tap callback (audio thread) and
    /// written by start/stop/reconfigure. Never held across file I/O.
    private let fileLock = NSLock()
    private var audioFile: AVAudioFile?

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

        let file = try AVAudioFile(
            forWriting: fileURL,
            settings: EncoderSettings.outputSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        setAudioFile(file)

        do {
            try installTap(inputFormat: inputFormat)
            engine.prepare()
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            setAudioFile(nil)
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
        setAudioFile(nil)
    }

    deinit {
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if _isCapturing {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
    }

    // MARK: - Tap installation

    /// Installs a tap on the input bus for `inputFormat`, converting to the
    /// mono 48 kHz processing format when the source format differs. Writes go
    /// to the currently-open `audioFile`, which stays the same across reconfigs.
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
                guard let self, let file = self.currentAudioFile() else { return }

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
                    do {
                        try file.write(from: convertedBuffer)
                    } catch {
                        print("[MicCapture] Write error: \(error)")
                    }
                }
            }
        } else {
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) {
                [weak self] buffer, _ in
                guard let self, let file = self.currentAudioFile() else { return }
                do {
                    try file.write(from: buffer)
                } catch {
                    print("[MicCapture] Write error: \(error)")
                }
            }
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

    private func setAudioFile(_ file: AVAudioFile?) {
        fileLock.lock()
        audioFile = file
        fileLock.unlock()
    }

    private func currentAudioFile() -> AVAudioFile? {
        fileLock.lock()
        defer { fileLock.unlock() }
        return audioFile
    }
}
