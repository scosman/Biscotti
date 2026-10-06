import AudioToolbox
@preconcurrency import AVFoundation
import Foundation
import os
import Synchronization

private let logger = Logger(subsystem: "net.scosman.biscotti.audiocapture", category: "LiveMicCapture")

/// Owns one recording attempt's file, conversion state and first-buffer anchor.
/// Each installed tap carries an identity checked under the same lock as writing.
/// Invalidating a tap waits for an in-flight write; subsequent callbacks are dropped.
/// Audio callbacks only try the lock, so they never wait for lifecycle operations.
final class MicCaptureSession: @unchecked Sendable {
    private final class Tap: Sendable {}

    private let processingFormat: AVAudioFormat
    private let onFirstBuffer: (@Sendable (Double) -> Void)?
    private let lock = OSAllocatedUnfairLock()
    /// Lifecycle reads must not contend with the audio callback for the write lock.
    private let deliveredBuffer = Atomic<Bool>(false)

    // The remaining mutable state is protected by lock.
    private var file: ExtAudioFileRef?
    private var activeTap: Tap?
    private var didNotifyFirstBuffer = false
    private var converter: AVAudioConverter?
    private var converterSourceFormat: AVAudioFormat?

    /// Opens a new file and captures this attempt's callback immutably. A later
    /// recorder retry cannot redirect an old tap to its own file or callback.
    init(url: URL, encoder: EncoderSettings, onFirstBuffer: (@Sendable (Double) -> Void)?) throws {
        processingFormat = encoder.processingFormat
        self.onFirstBuffer = onFirstBuffer
        file = try VPIOFileHelper.createExtAudioFile(
            url: url, encoder: encoder, processingFormat: processingFormat
        )
    }

    /// Whether the currently installed tap has received nonempty hardware audio.
    /// Replacing the tap resets this without resetting the session's first anchor.
    var hasDeliveredBuffer: Bool {
        deliveredBuffer.load(ordering: .acquiring)
    }

    /// Creates the callback installed on AVAudioEngine and retires the previous
    /// tap, including during a restart of the same engine. The file stays open.
    func makeTapHandler() -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        let tap = Tap()
        lock.lock()
        activeTap = tap
        deliveredBuffer.store(false, ordering: .releasing)
        converter = nil
        converterSourceFormat = nil
        lock.unlock()
        return { [self, tap] buffer, when in
            handleTap(buffer: buffer, when: when, tap: tap)
        }
    }

    /// Revokes the current tap before hardware teardown. Holding the write lock
    /// closes the check/write race even if a callback is already executing.
    func invalidateTap() {
        lock.lock()
        defer { lock.unlock() }
        activeTap = nil
        deliveredBuffer.store(false, ordering: .releasing)
        converter = nil
        converterSourceFormat = nil
    }

    /// Revokes all taps and finalizes this attempt's file. Idempotent, and
    /// safe even when a removed tap still retains its callback and this session.
    func close() {
        lock.lock()
        defer { lock.unlock() }
        activeTap = nil
        deliveredBuffer.store(false, ordering: .releasing)
        if let file { ExtAudioFileDispose(file) }
        file = nil
        converter = nil
        converterSourceFormat = nil
    }

    /// Finalizes a session if startup failed before its owner could close it.
    deinit { close() }

    /// Converts and writes only for the active tap. Ownership validation, graph
    /// readiness updates and first-anchor selection are serialized with invalidation.
    private func handleTap(buffer: AVAudioPCMBuffer, when: AVAudioTime, tap: Tap) {
        guard buffer.frameLength > 0, lock.lockIfAvailable() else { return }
        let anchor = writeBufferIfCurrent(buffer, when: when, tap: tap)
        lock.unlock()
        // The immutable callback belongs to this session, even if close/retry
        // happens after unlocking. It can only signal the old attempt's stream.
        if let anchor { onFirstBuffer?(anchor) }
    }

    /// Requires lock. Returns an anchor only after the first successful write;
    /// rejected, empty, unconvertible or failed buffers cannot confirm startup.
    private func writeBufferIfCurrent(_ buffer: AVAudioPCMBuffer, when: AVAudioTime, tap: Tap) -> Double? {
        guard activeTap === tap, let file else { return nil }
        deliveredBuffer.store(true, ordering: .releasing)
        guard let mono = VPIOBufferHelper.extractChannel0(buffer) else { return nil }
        let bufferToWrite: AVAudioPCMBuffer
        if mono.format.sampleRate == processingFormat.sampleRate {
            bufferToWrite = mono
        } else {
            guard let converter = converterForSource(mono.format),
                  let converted = VPIOBufferHelper.convert(mono, to: processingFormat, using: converter)
            else { return nil }
            bufferToWrite = converted
        }
        guard VPIOBufferHelper.writeBuffer(bufferToWrite, to: file) == noErr,
              !didNotifyFirstBuffer else { return nil }
        didNotifyFirstBuffer = true
        let anchor = when.isHostTimeValid
            ? Double(AudioConvertHostTimeToNanos(when.hostTime)) / 1_000_000_000
            : 0
        logger.notice("First mic buffer delivered -- anchor=\(anchor, privacy: .public)s")
        return anchor
    }

    /// Reuses conversion state only within the active tap and matching format.
    /// Requires lock so invalidation cannot reset a converter while it is in use.
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
