import Foundation

/// A plan for splitting audio into chunks for the reference API.
public struct ChunkPlan: Codable, Sendable, Equatable {
    public var sampleRate: Double
    public var chunks: [Chunk]

    public struct Chunk: Codable, Sendable, Equatable {
        public var index: Int
        public var startSample: Int
        public var endSample: Int
        public var cutRMS: Float?

        // Assumes 16 kHz (the only rate in this experiment).
        public var startSeconds: Double { Double(startSample) / 16000 }
        public var endSeconds: Double { Double(endSample) / 16000 }
        public var durationSeconds: Double { endSeconds - startSeconds }

        public init(index: Int, startSample: Int, endSample: Int, cutRMS: Float? = nil) {
            self.index = index
            self.startSample = startSample
            self.endSample = endSample
            self.cutRMS = cutRMS
        }
    }

    public init(sampleRate: Double = 16000, chunks: [Chunk]) {
        self.sampleRate = sampleRate
        self.chunks = chunks
    }
}

/// Plans how to split audio into chunks for the reference API upload.
///
/// Chunks are cut at the quietest 0.5-second window within +/-30 seconds of the
/// target cut point. No chunk exceeds `targetSeconds + 60` seconds except potentially
/// the final chunk (which can be at most `targetSeconds + 60`).
public enum ChunkPlanner {
    /// Plan chunks for the given sample range.
    ///
    /// - Parameters:
    ///   - samples: The full audio samples array.
    ///   - range: The sample range to chunk.
    ///   - targetSeconds: Target chunk length in seconds (default 300).
    ///   - searchSeconds: How far before/after the target to search for silence (default 30).
    ///   - windowSeconds: Duration of the RMS window for silence detection (default 0.5).
    ///   - hopSeconds: Step size for scanning windows (default 0.1).
    ///   - sampleRate: Sample rate in Hz (default 16000).
    /// - Returns: Array of chunks covering the range.
    public static func plan(
        samples: [Float],
        range: Range<Int>,
        targetSeconds: Double = 300,
        searchSeconds: Double = 30,
        windowSeconds: Double = 0.5,
        hopSeconds: Double = 0.1,
        sampleRate: Double = 16000
    ) -> [ChunkPlan.Chunk] {
        let sr = sampleRate
        let targetSamples = Int(targetSeconds * sr)
        let overflowSamples = Int(60 * sr) // max allowed beyond target
        let windowSamples = Int(windowSeconds * sr)
        let hopSamples = max(1, Int(hopSeconds * sr))
        let searchSamples = Int(searchSeconds * sr)

        var chunks: [ChunkPlan.Chunk] = []
        var pos = range.lowerBound

        while range.upperBound - pos > targetSamples + overflowSamples {
            let target = pos + targetSamples

            // Search for the quietest window in [target - search, target + search],
            // clamped to the valid range.
            let searchStart = max(pos + windowSamples, target - searchSamples)
            let searchEnd = min(range.upperBound - windowSamples, target + searchSamples)

            if searchStart >= searchEnd {
                // No room to search; cut at target.
                chunks.append(ChunkPlan.Chunk(
                    index: chunks.count,
                    startSample: pos,
                    endSample: target,
                    cutRMS: nil
                ))
                pos = target
                continue
            }

            var bestCenter = target
            var bestRMS = Float.greatestFiniteMagnitude

            var center = searchStart
            while center <= searchEnd {
                let windowStart = center - windowSamples / 2
                let windowEnd = center + windowSamples / 2
                let clampedStart = max(range.lowerBound, windowStart)
                let clampedEnd = min(range.upperBound, windowEnd)

                if clampedEnd > clampedStart {
                    let rms = computeRMS(samples: samples, start: clampedStart, end: clampedEnd)
                    if rms < bestRMS {
                        bestRMS = rms
                        bestCenter = center
                    }
                }
                center += hopSamples
            }

            chunks.append(ChunkPlan.Chunk(
                index: chunks.count,
                startSample: pos,
                endSample: bestCenter,
                cutRMS: bestRMS < Float.greatestFiniteMagnitude ? bestRMS : nil
            ))
            pos = bestCenter
        }

        // Final chunk: whatever remains.
        if pos < range.upperBound {
            chunks.append(ChunkPlan.Chunk(
                index: chunks.count,
                startSample: pos,
                endSample: range.upperBound,
                cutRMS: nil
            ))
        }

        return chunks
    }

    /// Compute the RMS of a slice of samples.
    static func computeRMS(samples: [Float], start: Int, end: Int) -> Float {
        guard end > start else { return 0 }
        var sumSquares: Double = 0
        for i in start ..< end {
            let s = Double(samples[i])
            sumSquares += s * s
        }
        return Float((sumSquares / Double(end - start)).squareRoot())
    }
}
