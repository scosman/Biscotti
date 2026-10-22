import Foundation
import STTLabCore
@testable import STTLabHome
import Testing

/// Helper to create a ChunkMeta with the given sample range and HTTP status.
private func makeMeta(
    index: Int,
    start: Int,
    end: Int,
    httpStatus: Int = 200
) -> ChunkMeta {
    ChunkMeta(
        chunkIndex: index,
        startSample: start,
        endSample: end,
        startSeconds: Double(start) / 16000,
        endSeconds: Double(end) / 16000,
        requestMetadata: ["model": "test"],
        httpStatus: httpStatus,
        responseHeaders: [:],
        attempts: 1,
        latencySeconds: 1.0,
        requestedAt: Date(timeIntervalSinceReferenceDate: 0)
    )
}

/// Write a fake response file at the expected path for a chunk meta.
private func writeStubResponse(meta: ChunkMeta, dir: URL) throws {
    let prefix = ReferenceRunner.chunkFilePrefix(start: meta.startSample, end: meta.endSample)
    let responseURL = dir.appendingPathComponent("\(prefix).response.json")
    let json = "{\"text\":\"stub\",\"usage\":{\"cost\":0.001}}"
    try Data(json.utf8).write(to: responseURL)
    try JSONFiles.write(meta, to: dir.appendingPathComponent("\(prefix).meta.json"))
}

// MARK: - Sub-chunk collision tests

@Suite("Sub-chunk files do not collide with plan chunk files")
struct SubChunkCollisionTests {
    @Test("Split sub-chunks for chunk 0 do not affect chunk 1 resume check")
    func splitSubChunksDoNotAffectNextPlanChunk() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sttlab-collision-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Plan: chunk 0 covers [0, 4_800_000), chunk 1 covers [4_800_000, 9_600_000).
        let planChunk0 = ChunkPlan.Chunk(index: 0, startSample: 0, endSample: 4_800_000)
        let planChunk1 = ChunkPlan.Chunk(index: 1, startSample: 4_800_000, endSample: 9_600_000)

        // Simulate: chunk 0 was split into two sub-chunks and completed.
        let sub0 = makeMeta(index: 0, start: 0, end: 2_400_000)
        let sub1 = makeMeta(index: 1, start: 2_400_000, end: 4_800_000)
        try writeStubResponse(meta: sub0, dir: dir)
        try writeStubResponse(meta: sub1, dir: dir)

        // Write done marker for chunk 0 (lists its sub-chunk metas).
        let donePrefix = ReferenceRunner.chunkFilePrefix(start: 0, end: 4_800_000)
        let doneURL = dir.appendingPathComponent("\(donePrefix).done.json")
        try JSONFiles.write([sub0, sub1], to: doneURL)

        // Chunk 0 is completed (via split done marker).
        let result0 = ReferenceRunner.checkChunkCompletion(chunk: planChunk0, dir: dir)
        #expect(result0 != nil)
        #expect(result0?.count == 2)

        // Chunk 1 is NOT completed (no files written for its range).
        let result1 = ReferenceRunner.checkChunkCompletion(chunk: planChunk1, dir: dir)
        #expect(result1 == nil)
    }

    @Test("Sub-chunk file names never match other plan chunk file names")
    func subChunkFileNamesNeverMatchOtherPlanChunks() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sttlab-naming-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Write sub-chunk files for chunk 0's split.
        let sub0 = makeMeta(index: 0, start: 0, end: 2_400_000)
        let sub1 = makeMeta(index: 1, start: 2_400_000, end: 4_800_000)
        try writeStubResponse(meta: sub0, dir: dir)
        try writeStubResponse(meta: sub1, dir: dir)

        // Verify chunk 1's expected file path does not exist.
        let chunk1Prefix = ReferenceRunner.chunkFilePrefix(start: 4_800_000, end: 9_600_000)
        let chunk1Response = dir.appendingPathComponent("\(chunk1Prefix).response.json")
        let chunk1Meta = dir.appendingPathComponent("\(chunk1Prefix).meta.json")

        #expect(!FileManager.default.fileExists(atPath: chunk1Response.path))
        #expect(!FileManager.default.fileExists(atPath: chunk1Meta.path))
    }
}

// MARK: - Resume-after-split tests

@Suite("Resume after split does not re-send covered ranges")
struct ResumeAfterSplitTests {
    @Test("Done marker with sub-chunk metas causes chunk to be skipped")
    func doneMarkerSkipsChunk() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sttlab-resume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let planChunk = ChunkPlan.Chunk(index: 0, startSample: 0, endSample: 4_800_000)

        // Write split sub-chunk results + done marker.
        let sub0 = makeMeta(index: 0, start: 0, end: 2_400_000)
        let sub1 = makeMeta(index: 1, start: 2_400_000, end: 4_800_000)
        try writeStubResponse(meta: sub0, dir: dir)
        try writeStubResponse(meta: sub1, dir: dir)

        let donePrefix = ReferenceRunner.chunkFilePrefix(start: 0, end: 4_800_000)
        try JSONFiles.write([sub0, sub1], to: dir.appendingPathComponent("\(donePrefix).done.json"))

        // The chunk is detected as complete.
        let result = ReferenceRunner.checkChunkCompletion(chunk: planChunk, dir: dir)
        #expect(result != nil)
        #expect(result?.count == 2)
    }

    @Test("Fallback: meta file without done marker still resumes a non-split chunk")
    func metaFileFallbackResumesNonSplitChunk() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sttlab-fallback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let planChunk = ChunkPlan.Chunk(index: 0, startSample: 0, endSample: 4_800_000)

        // Write only the meta + response files (no done marker — simulates a
        // crash between file write and done-marker write).
        let meta = makeMeta(index: 0, start: 0, end: 4_800_000)
        try writeStubResponse(meta: meta, dir: dir)

        let result = ReferenceRunner.checkChunkCompletion(chunk: planChunk, dir: dir)
        #expect(result != nil)
        #expect(result?.count == 1)
    }

    @Test("Failed sub-chunk in done marker does NOT skip the chunk")
    func failedSubChunkDoesNotSkip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sttlab-failed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let planChunk = ChunkPlan.Chunk(index: 0, startSample: 0, endSample: 4_800_000)

        // One sub-chunk succeeded, one has a 500 status.
        let sub0 = makeMeta(index: 0, start: 0, end: 2_400_000, httpStatus: 200)
        let sub1 = makeMeta(index: 1, start: 2_400_000, end: 4_800_000, httpStatus: 500)

        let donePrefix = ReferenceRunner.chunkFilePrefix(start: 0, end: 4_800_000)
        try JSONFiles.write([sub0, sub1], to: dir.appendingPathComponent("\(donePrefix).done.json"))

        // Not complete because one sub-chunk failed.
        let result = ReferenceRunner.checkChunkCompletion(chunk: planChunk, dir: dir)
        #expect(result == nil)
    }

    @Test("Empty directory returns nil (chunk needs processing)")
    func emptyDirReturnsNil() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sttlab-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let planChunk = ChunkPlan.Chunk(index: 0, startSample: 0, endSample: 4_800_000)
        let result = ReferenceRunner.checkChunkCompletion(chunk: planChunk, dir: dir)
        #expect(result == nil)
    }

    @Test("Full plan: split chunk 0 done, chunk 1 not done, chunk 2 done directly")
    func mixedCompletionStates() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sttlab-mixed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Three plan chunks.
        let chunk0 = ChunkPlan.Chunk(index: 0, startSample: 0, endSample: 4_800_000)
        let chunk1 = ChunkPlan.Chunk(index: 1, startSample: 4_800_000, endSample: 9_600_000)
        let chunk2 = ChunkPlan.Chunk(index: 2, startSample: 9_600_000, endSample: 14_400_000)

        // Chunk 0: completed via split.
        let sub0a = makeMeta(index: 0, start: 0, end: 2_400_000)
        let sub0b = makeMeta(index: 1, start: 2_400_000, end: 4_800_000)
        try writeStubResponse(meta: sub0a, dir: dir)
        try writeStubResponse(meta: sub0b, dir: dir)
        let done0Prefix = ReferenceRunner.chunkFilePrefix(start: 0, end: 4_800_000)
        try JSONFiles.write([sub0a, sub0b], to: dir.appendingPathComponent("\(done0Prefix).done.json"))

        // Chunk 1: not done (no files).

        // Chunk 2: completed directly (single meta + response + done marker).
        let meta2 = makeMeta(index: 2, start: 9_600_000, end: 14_400_000)
        try writeStubResponse(meta: meta2, dir: dir)
        let done2Prefix = ReferenceRunner.chunkFilePrefix(start: 9_600_000, end: 14_400_000)
        try JSONFiles.write([meta2], to: dir.appendingPathComponent("\(done2Prefix).done.json"))

        // Verify: chunk 0 complete (2 sub-chunks), chunk 1 needs work, chunk 2 complete (1 chunk).
        let result0 = ReferenceRunner.checkChunkCompletion(chunk: chunk0, dir: dir)
        #expect(result0?.count == 2)

        let result1 = ReferenceRunner.checkChunkCompletion(chunk: chunk1, dir: dir)
        #expect(result1 == nil)

        let result2 = ReferenceRunner.checkChunkCompletion(chunk: chunk2, dir: dir)
        #expect(result2?.count == 1)
    }
}
