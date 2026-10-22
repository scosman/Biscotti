import Foundation
@testable import STTLabHome
import Testing

@Suite("ChunkPlanner")
struct ChunkPlannerTests {
    /// Short audio (under target) returns a single chunk covering the full range.
    @Test("Single chunk for short audio")
    func singleChunkForShortAudio() {
        let sampleRate = 16000.0
        let durationSeconds = 120.0 // 2 minutes, well under default 300s target
        let sampleCount = Int(durationSeconds * sampleRate)
        let samples = [Float](repeating: 0.1, count: sampleCount)

        let chunks = ChunkPlanner.plan(
            samples: samples,
            range: 0 ..< sampleCount,
            targetSeconds: 300
        )

        #expect(chunks.count == 1)
        #expect(chunks[0].startSample == 0)
        #expect(chunks[0].endSample == sampleCount)
    }

    /// Audio exactly at target + 60 returns a single chunk (just at the boundary).
    @Test("Boundary: target + 60 seconds returns one chunk")
    func boundaryOneChunk() {
        let sampleRate = 16000.0
        let target = 300.0
        let overflow = 60.0
        let sampleCount = Int((target + overflow) * sampleRate)
        let samples = [Float](repeating: 0.01, count: sampleCount)

        let chunks = ChunkPlanner.plan(
            samples: samples,
            range: 0 ..< sampleCount,
            targetSeconds: target
        )

        // Should be exactly 1 chunk -- right at the boundary.
        #expect(chunks.count == 1)
    }

    /// Audio that exceeds target + 60 gets split into multiple chunks.
    @Test("Splits long audio into multiple chunks")
    func splitsLongAudio() {
        let sampleRate = 16000.0
        let durationSeconds = 900.0 // 15 minutes
        let sampleCount = Int(durationSeconds * sampleRate)
        // Uniform samples (no silence variation).
        let samples = [Float](repeating: 0.05, count: sampleCount)

        let chunks = ChunkPlanner.plan(
            samples: samples,
            range: 0 ..< sampleCount,
            targetSeconds: 300
        )

        #expect(chunks.count >= 2)

        // All chunks cover the full range without gaps or overlaps.
        #expect(chunks.first!.startSample == 0)
        #expect(chunks.last!.endSample == sampleCount)

        for i in 1 ..< chunks.count {
            #expect(chunks[i].startSample == chunks[i - 1].endSample,
                    "Chunk \(i) should start where chunk \(i - 1) ends")
        }

        // Indices are sequential.
        for (i, chunk) in chunks.enumerated() {
            #expect(chunk.index == i)
        }
    }

    /// Chunks cut at silent gaps when silence exists near the target.
    @Test("Cuts at silence when available")
    func cutsAtSilence() {
        let sampleRate = 16000.0
        // Use 350s so it just barely needs to split (>300+60=360s would be one chunk,
        // but we want exactly 2 chunks). Use a smaller target to force the split.
        let durationSeconds = 600.0
        let sampleCount = Int(durationSeconds * sampleRate)
        var samples = [Float](repeating: 0.5, count: sampleCount)

        // Insert a silent gap at 195-205 seconds (within search range of 200s target).
        let silenceStart = Int(195 * sampleRate)
        let silenceEnd = Int(205 * sampleRate)
        for i in silenceStart ..< min(silenceEnd, sampleCount) {
            samples[i] = 0.0
        }

        let chunks = ChunkPlanner.plan(
            samples: samples,
            range: 0 ..< sampleCount,
            targetSeconds: 200,
            searchSeconds: 30,
            windowSeconds: 0.5,
            hopSeconds: 0.1
        )

        // Should have at least 2 chunks.
        #expect(chunks.count >= 2)

        // The first cut should be inside the silent region.
        let cutSample = chunks[0].endSample
        let cutSeconds = Double(cutSample) / sampleRate
        #expect(cutSeconds >= 195)
        #expect(cutSeconds <= 205)

        // The first chunk should have a low cutRMS.
        if let rms = chunks[0].cutRMS {
            #expect(rms < 0.01)
        }
    }

    /// No chunk exceeds targetSeconds + 60 (except possibly the last).
    @Test("Chunk length limit")
    func chunkLengthLimits() {
        let sampleRate = 16000.0
        let durationSeconds = 1500.0 // 25 minutes
        let sampleCount = Int(durationSeconds * sampleRate)
        let samples = [Float](repeating: 0.1, count: sampleCount)

        let target = 300.0
        let chunks = ChunkPlanner.plan(
            samples: samples,
            range: 0 ..< sampleCount,
            targetSeconds: target
        )

        let maxSamples = Int((target + 60) * sampleRate)
        for chunk in chunks {
            let chunkSamples = chunk.endSample - chunk.startSample
            #expect(chunkSamples <= maxSamples + 1)
        }
    }

    /// Deterministic: same input produces the same plan.
    @Test("Deterministic output")
    func deterministic() {
        let sampleRate = 16000.0
        let sampleCount = Int(600 * sampleRate)
        var samples = [Float](repeating: 0.3, count: sampleCount)
        // Add some variation.
        for i in stride(from: 0, to: sampleCount, by: 1600) {
            samples[i] = 0.0
        }

        let plan1 = ChunkPlanner.plan(samples: samples, range: 0 ..< sampleCount, targetSeconds: 200)
        let plan2 = ChunkPlanner.plan(samples: samples, range: 0 ..< sampleCount, targetSeconds: 200)

        #expect(plan1.count == plan2.count)
        for (a, b) in zip(plan1, plan2) {
            #expect(a == b)
        }
    }
}
