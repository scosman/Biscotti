import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import AudioCapture

/// A drained `LiveAudioBlock` with its samples copied out of the queue.
struct DrainedBlock: Equatable {
    enum Kind: Equatable {
        case samples([Float], sampleRate: Double, channelCount: Int)
        case gap(duration: TimeInterval, kind: LiveAudioGapKind)
        case end
    }

    let startTime: TimeInterval
    let kind: Kind

    init(startTime: TimeInterval, kind: Kind) {
        self.startTime = startTime
        self.kind = kind
    }

    init(_ block: LiveAudioBlock) {
        startTime = block.startTime
        switch block.kind {
        case let .samples(samples, sampleRate, channelCount):
            kind = .samples(Array(samples), sampleRate: sampleRate, channelCount: channelCount)
        case let .gap(duration, gapKind):
            kind = .gap(duration: duration, kind: gapKind)
        case .end:
            kind = .end
        }
    }

    var duration: TimeInterval {
        switch kind {
        case let .samples(samples, sampleRate, channelCount):
            Double(samples.count / channelCount) / sampleRate
        case let .gap(duration, _):
            duration
        case .end:
            0
        }
    }

    var endTime: TimeInterval {
        startTime + duration
    }

    var samples: [Float]? {
        if case let .samples(samples, _, _) = kind { return samples }
        return nil
    }

    var frameCount: Int {
        if case let .samples(samples, _, channelCount) = kind { return samples.count / channelCount }
        return 0
    }

    var sampleRate: Double? {
        if case let .samples(_, sampleRate, _) = kind { return sampleRate }
        return nil
    }

    var channelCount: Int? {
        if case let .samples(_, _, channelCount) = kind { return channelCount }
        return nil
    }

    var gapKind: LiveAudioGapKind? {
        if case let .gap(_, kind) = kind { return kind }
        return nil
    }
}

extension LiveAudioQueue {
    /// Drains whatever the queue holds now.
    func drainAll() -> [DrainedBlock] {
        var blocks: [DrainedBlock] = []
        drain { blocks.append(DrainedBlock($0)) }
        return blocks
    }
}

extension Collection<DrainedBlock> {
    var sampleBlocks: [DrainedBlock] {
        filter { $0.samples != nil }
    }

    var gaps: [DrainedBlock] {
        filter { $0.gapKind != nil }
    }

    /// Every sample of the sample blocks, in order.
    var allSamples: [Float] {
        flatMap { $0.samples ?? [] }
    }

    /// Records an issue where a block (`.end` included) does not start where
    /// the previous one ended.
    func expectContinuous(from start: TimeInterval = 0, sourceLocation: SourceLocation = #_sourceLocation) {
        var expected = start
        for (index, block) in enumerated() {
            #expect(
                abs(block.startTime - expected) < 1e-9,
                "Block \(index) starts at \(block.startTime), expected \(expected)",
                sourceLocation: sourceLocation
            )
            expected = block.endTime
        }
    }
}

/// Drains a queue on its own thread until `.end`, as the live pump will.
final class BackgroundDrainer: @unchecked Sendable {
    private let queue: LiveAudioQueue
    private let blocks = Mutex<[DrainedBlock]>([])
    private let done = DispatchSemaphore(value: 0)

    init(_ queue: LiveAudioQueue) {
        self.queue = queue
        let thread = Thread { [self] in run() }
        thread.name = "live-audio-test-drainer"
        thread.start()
    }

    /// Waits for `.end` (the queue must be closed) and returns every block.
    func finish() -> [DrainedBlock] {
        done.wait()
        return blocks.withLock { $0 }
    }

    private func run() {
        var sawEnd = false
        while !sawEnd {
            queue.drain { block in
                let drained = DrainedBlock(block)
                if drained.kind == .end { sawEnd = true }
                blocks.withLock { $0.append(drained) }
            }
            if !sawEnd { Thread.sleep(forTimeInterval: 0.001) }
        }
        done.signal()
    }
}

/// Taps a phase-continuous tone into a mic session in fixed-size buffers with
/// contiguous host times, as VPIO delivers it. Channel 0 carries the tone;
/// any other channels carry a second tone that must not reach the file.
struct MicToneFeed {
    let format: AVAudioFormat
    let bufferFrames: Int
    let toneHz: Double

    /// Channel 0 of every buffer tapped, in order.
    private(set) var playedChannel0: [Float] = []

    private var frameIndex = 0
    private var hostNanos: UInt64 = 1_000_000_000
    private var buffersSinceFlush = 0

    init(sampleRate: Double, channelCount: Int, bufferFrames: Int, toneHz: Double = 400) throws {
        let layout = try #require(AVAudioChannelLayout(
            layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channelCount)
        ))
        format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channelLayout: layout)
        self.bufferFrames = bufferFrames
        self.toneHz = toneHz
    }

    /// Taps `seconds` of tone, flushing the session's writer now and then so
    /// its ring never fills.
    mutating func play(
        seconds: Double,
        into session: MicCaptureSession,
        tap: (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) throws {
        let rate = format.sampleRate
        var remaining = Int((seconds * rate).rounded())
        while remaining > 0 {
            let count = min(bufferFrames, remaining)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
            buffer.frameLength = AVAudioFrameCount(count)
            let channels = try #require(buffer.floatChannelData)
            for frame in 0 ..< count {
                let time = Double(frameIndex + frame) / rate
                channels[0][frame] = Float(0.3 * sin(2 * Double.pi * toneHz * time))
                for channel in 1 ..< Int(format.channelCount) {
                    channels[channel][frame] = Float(0.3 * sin(2 * Double.pi * 1700 * time + Double(channel)))
                }
            }
            playedChannel0.append(contentsOf: UnsafeBufferPointer(start: channels[0], count: count))
            tap(buffer, AVAudioTime(hostTime: AudioConvertNanosToHostTime(hostNanos)))
            frameIndex += count
            hostNanos += UInt64((Double(count) / rate * 1_000_000_000).rounded())
            remaining -= count
            buffersSinceFlush += 1
            if buffersSinceFlush == 64 {
                session.flushWriter()
                buffersSinceFlush = 0
            }
        }
    }

    /// Lets host time pass with no buffers, as during a reconnect.
    mutating func pause(seconds: Double) {
        hostNanos += UInt64((seconds * 1_000_000_000).rounded())
    }
}
