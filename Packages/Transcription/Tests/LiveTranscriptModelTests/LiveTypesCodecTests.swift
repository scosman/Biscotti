import Foundation
import Testing
@testable import LiveTranscriptModel

@Suite("Live types codecs")
struct LiveTypesCodecTests {
    private static let edgeSamples: [Float] = [
        0, -0.0, 1, -1, 0.5, -0.25, .greatestFiniteMagnitude, -.greatestFiniteMagnitude,
        .leastNonzeroMagnitude, .infinity, -.infinity
    ]

    @Test("An audio chunk round-trips through its XPC data")
    func chunkRoundTripsThroughXPCData() throws {
        var generator = SeededGenerator(seed: 7)
        let noise = (0 ..< 4000).map { _ in Float.random(in: -1 ... 1, using: &generator) }
        let chunk = LiveAudioChunk(track: .system, startTime: 12.375, samples: Self.edgeSamples + noise, isDiscontinuity: true)

        let decoded = try LiveAudioChunk(xpcData: chunk.encodedForXPC())
        #expect(decoded == chunk)
        #expect(decoded.samples.map(\.bitPattern) == chunk.samples.map(\.bitPattern), "Signed zeros survive")

        let empty = LiveAudioChunk(track: .mixed, startTime: 0, samples: [])
        #expect(try LiveAudioChunk(xpcData: empty.encodedForXPC()) == empty)
    }

    @Test("A chunk decodes from a Data slice that does not start at index 0")
    func chunkDecodesFromDataSlice() throws {
        let chunk = LiveAudioChunk(track: .mic, startTime: 3, samples: [0.1, 0.2, 0.3])
        let padded = Data([0xAB, 0xCD, 0xEF]) + chunk.encodedForXPC()
        let slice = padded.dropFirst(3)
        #expect(slice.startIndex == 3)
        #expect(try LiveAudioChunk(xpcData: slice) == chunk)
    }

    @Test("Malformed chunk data throws instead of trapping")
    func malformedChunkDataThrows() throws {
        let valid = LiveAudioChunk(track: .mic, startTime: 1, samples: [1, 2, 3]).encodedForXPC()

        #expect(throws: LiveAudioChunkCodingError.truncatedHeader) {
            try LiveAudioChunk(xpcData: Data([1, 2, 3]))
        }
        #expect(throws: LiveAudioChunkCodingError.truncatedHeader) {
            try LiveAudioChunk(xpcData: valid.prefix(12))
        }

        var badHeader = Data()
        withUnsafeBytes(of: UInt64(4).littleEndian) { badHeader.append(contentsOf: $0) }
        badHeader.append(contentsOf: Array("nope".utf8))
        #expect(throws: LiveAudioChunkCodingError.malformedHeader) {
            try LiveAudioChunk(xpcData: badHeader)
        }

        #expect(throws: LiveAudioChunkCodingError.sampleCountMismatch(expected: 3, actual: 2)) {
            try LiveAudioChunk(xpcData: valid.dropLast(4))
        }
        #expect(throws: LiveAudioChunkCodingError.sampleCountMismatch(expected: 3, actual: 3)) {
            try LiveAudioChunk(xpcData: valid + Data([0, 0]))
        }
    }

    @Test("Chunk duration and end time follow the 16 kHz sample count")
    func chunkDurationFollowsSampleCount() {
        let chunk = LiveAudioChunk(track: .mic, startTime: 10, samples: Array(repeating: 0, count: 4000))
        #expect(chunk.duration == 0.25)
        #expect(chunk.endTime == 10.25)
    }

    @Test("A track update round-trips through JSON")
    func updateRoundTripsThroughJSON() throws {
        let update = LiveTrackUpdate(
            sessionID: UUID(),
            generation: 2,
            track: .system,
            revision: 41,
            rows: [
                LiveRow(track: .system, startTime: 1, endTime: 2.5, settledText: "We shipped", isClosed: true, isForcedBoundary: true),
                LiveRow(track: .system, startTime: 4, endTime: 5, settledText: "it", tailText: " today", isIncomplete: true)
            ],
            gaps: [
                LiveGap(track: .system, startTime: 2.5, duration: 1.5, reason: .queueOverflow),
                LiveGap(track: .system, startTime: 6, duration: 12, reason: .paused)
            ],
            transcribedThrough: 5.5,
            settledThrough: 4,
            detectedLanguage: "de",
            decodeMilliseconds: 412.5
        )

        let decoded = try JSONDecoder().decode(LiveTrackUpdate.self, from: JSONEncoder().encode(update))
        #expect(decoded == update)
    }

    @Test("A session config round-trips through JSON with every language policy", arguments: [
        LiveLanguage.english, .detect, .locale("fr-FR")
    ])
    func configRoundTripsThroughJSON(language: LiveLanguage) throws {
        let config = LiveSessionConfig(
            sessionID: UUID(),
            generation: 1,
            engine: .whisper,
            whisperModel: "openai_whisper-large-v3-v20240930_626MB",
            tracks: [.mic, .system],
            updateInterval: 2,
            language: language,
            vocabulary: ["Biscotti", "SpeakerKit"]
        )

        let decoded = try JSONDecoder().decode(LiveSessionConfig.self, from: JSONEncoder().encode(config))
        #expect(decoded == config)
    }

    @Test("A gap keeps whether it was silent through JSON; one encoded without it is not silent")
    func gapSilenceRoundTripsAndDefaultsToNotSilent() throws {
        let gap = LiveGap(track: .system, startTime: 3, duration: 2, reason: .queueOverflow, isSilent: true)
        #expect(try JSONDecoder().decode(LiveGap.self, from: JSONEncoder().encode(gap)) == gap)

        let older = Data(#"{"track":"mic","startTime":1,"duration":2,"reason":"paused"}"#.utf8)
        #expect(try JSONDecoder().decode(LiveGap.self, from: older) == LiveGap(track: .mic, startTime: 1, duration: 2, reason: .paused))
    }

    @Test("The audio handed to the engine ahead of its settled time and the chunks in transit fit the session's retention")
    func engineLeadFitsTheSessionRetention() {
        #expect(LiveAudioLimits.engineLead + LiveAudioLimits.inTransit < LiveAudioLimits.sessionRetention)
        // A full catch-up window can be handed over, and is backfill well before it is.
        #expect(LiveAudioLimits.catchUpWindow < LiveAudioLimits.engineLead)
        #expect(LiveAudioLimits.backfillLag < LiveAudioLimits.catchUpWindow)
        #expect(LiveAudioLimits.pumpBacklog == 15 * 60)
    }

    @Test("A chunk keeps whether it is backfill through XPC; a header without it is live audio")
    func backfillRoundTripsAndDefaultsToLive() throws {
        let chunk = LiveAudioChunk(track: .system, startTime: 12, samples: [0.5, -0.25], isBackfill: true)
        #expect(try LiveAudioChunk(xpcData: chunk.encodedForXPC()) == chunk)

        let header = Data(#"{"track":"mic","startTime":1,"isDiscontinuity":false,"sampleCount":0}"#.utf8)
        var older = Data()
        withUnsafeBytes(of: UInt64(header.count).littleEndian) { older.append(contentsOf: $0) }
        older.append(header)
        #expect(try LiveAudioChunk(xpcData: older) == LiveAudioChunk(track: .mic, startTime: 1, samples: []))
    }
}
