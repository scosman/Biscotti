import AudioToolbox
import Foundation
import os
import QuartzCore

private let logger = Logger(subsystem: "net.scosman.biscotti.audiocapture", category: "LiveSystemCapture")

/// Writes one system-tap buffer to the track's ADTS file: leading silence
/// before the file's first buffer, silence for a capture gap, then the buffer
/// itself. Each is reported to the live queue at its place on the recording
/// timeline; the buffer's samples are copied once the file has taken them.
///
/// Writer-thread only, except `begin`, which `LiveSystemCaptureEngine.start`
/// calls before the writer thread starts, once per new file. Reconnects keep
/// the step, so gap detection and the timeline span them.
final class SystemWriteStep {
    /// Absolute backstop on prepended silence (seconds).
    static let maxLeadingSilenceSeconds: Double = 3600

    private let gapFillWriter = SystemGapFillWriter()
    private var liveQueue: LiveAudioQueue?

    /// Host-clock seconds of the mic's first written frame: the recording's t = 0.
    private var micAnchorSeconds: Double = 0

    /// `CACurrentMediaTime()` when system capture started. Bounds the
    /// leading silence by how long capture has actually run, so a bogus
    /// anchor cannot write hours of silence.
    private var systemStartWall: CFTimeInterval = 0

    private var didWriteLeadingSilence = false

    /// Audio written to the file so far, including silence, at the client
    /// rate: the start time of the next block copied to `liveQueue`.
    private var timeline = WrittenTimeline()

    /// First failed gap fill or buffer write since `begin`.
    private(set) var writeError: OSStatus?

    /// Prepares for a new file. The leading silence aligns its first buffer
    /// with `micAnchorSeconds`.
    func begin(micAnchorSeconds: Double, systemStartWall: CFTimeInterval, liveQueue: LiveAudioQueue?) {
        self.micAnchorSeconds = micAnchorSeconds
        self.systemStartWall = systemStartWall
        self.liveQueue = liveQueue
        didWriteLeadingSilence = false
        timeline = WrittenTimeline()
        writeError = nil
        gapFillWriter.reset()
    }

    /// Writes `entry` (interleaved Float32 at `sampleRate`, the file's client
    /// format) and any silence that must come before it.
    func write(_ entry: AudioRingBuffer.Entry, sampleRate: Double, to file: ExtAudioFileRef) {
        let channelCount = max(entry.channelCount, 1)

        // Before the first real frame, prepend leading silence so the
        // system track's first frame lines up with the mic's first frame
        // (the recording's t=0).
        if !didWriteLeadingSilence {
            didWriteLeadingSilence = true
            writeLeadingSilence(
                channelCount: channelCount,
                firstFrameHostTime: entry.hostTime,
                sampleRate: sampleRate,
                file: file
            )
        }

        // Fill any gap since the last buffer with silence so the system
        // track stays aligned with wall-clock time after reconnects.
        // Measured from IOProc host-clock timestamps (capture side), not
        // writer-thread timing.
        let filledFrames = gapFillWriter.processBuffer(
            hostTimeNanos: AudioConvertHostTimeToNanos(entry.hostTime),
            bufferFrameCount: entry.frameCount,
            channelCount: entry.channelCount,
            sampleRate: sampleRate,
            file: file
        )
        if let gapError = gapFillWriter.writeError { recordWriteError(gapError) }
        recordSilence(frames: filledFrames, sampleRate: sampleRate, kind: .captureGap)

        writeBuffer(entry, channelCount: channelCount, sampleRate: sampleRate, file: file)
    }

    private func writeBuffer(
        _ entry: AudioRingBuffer.Entry,
        channelCount: UInt32,
        sampleRate: Double,
        file: ExtAudioFileRef
    ) {
        let frameCount = Int(entry.frameCount)
        let sampleCount = frameCount * Int(channelCount)
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
        guard writeStatus == noErr else {
            logger.error("ExtAudioFileWrite failed: \(writeStatus, privacy: .public)")
            recordWriteError(writeStatus)
            return
        }

        // Only audio the file took goes to the live copy, so the live timeline
        // stays the file's.
        if let liveQueue {
            entry.data.withMemoryRebound(to: Float.self, capacity: sampleCount) { samples in
                liveQueue.pushSamples(
                    samples, frameCount: frameCount, sampleRate: sampleRate,
                    channelCount: Int(channelCount), startTime: timeline.seconds
                )
            }
        }
        timeline.advance(frames: frameCount, sampleRate: sampleRate)
    }

    /// Writes `systemFirstFrame − micAnchor` worth of silent frames to the
    /// front of the file so the system track aligns with the mic track.
    /// `firstFrameHostTime` is the mach host time of the system tap's first
    /// captured frame. Runs once per file (allocation is fine here).
    private func writeLeadingSilence(
        channelCount: UInt32,
        firstFrameHostTime: UInt64,
        sampleRate: Double,
        file: ExtAudioFileRef
    ) {
        let hostNanos = AudioConvertHostTimeToNanos(firstFrameHostTime)
        let totalFrames = leadingSilenceFrameCount(
            systemHostTimeNanos: hostNanos,
            micAnchorSeconds: micAnchorSeconds,
            systemStartWall: systemStartWall,
            currentWall: CACurrentMediaTime(),
            sampleRate: sampleRate,
            maxLeadingSilenceSeconds: Self.maxLeadingSilenceSeconds
        )
        guard totalFrames > 0 else { return }

        logger.info("Aligning system track: prepending \(totalFrames) frames of leading silence")
        recordSilence(frames: totalFrames, sampleRate: sampleRate, kind: .notStarted)

        var framesRemaining = totalFrames
        let channels = Int(channelCount)
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

    /// Reports silence the file holds at the current written time.
    private func recordSilence(frames: Int, sampleRate: Double, kind: LiveAudioGapKind) {
        guard frames > 0 else { return }
        liveQueue?.pushGap(
            startTime: timeline.seconds,
            duration: Double(frames) / sampleRate,
            kind: kind
        )
        timeline.advance(frames: frames, sampleRate: sampleRate)
    }

    private func recordWriteError(_ status: OSStatus) {
        if writeError == nil { writeError = status }
    }
}
