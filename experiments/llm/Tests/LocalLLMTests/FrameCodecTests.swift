import Foundation
import Testing

@testable import LocalLLM

// MARK: - FrameCodec Encode/Decode Tests

@Suite("FrameCodec")
struct FrameCodecTests {
    // MARK: - Basic Round-Trips

    @Test("ServiceRequest round-trips through encode/decode")
    func serviceRequestRoundTrip() throws {
        let request = ServiceRequest.generate(
            id: 1, prompt: "Hello", system: "Be helpful", options: .default, streaming: true
        )
        let frame = try FrameCodec.encode(request)

        // Write to a pipe so we can read from a FileHandle.
        let pipe = Pipe()
        pipe.fileHandleForWriting.write(frame)
        pipe.fileHandleForWriting.closeFile()

        let decoded = try FrameCodec.decode(ServiceRequest.self, from: pipe.fileHandleForReading)
        #expect(decoded == request)
    }

    @Test("ServiceEvent round-trips through encode/decode")
    func serviceEventRoundTrip() throws {
        let result = GenerationResult(
            text: "42", reasoning: nil, promptTokenCount: 10, generatedTokenCount: 5,
            finishReason: .endOfTurn, loadDuration: nil, promptEvalDuration: 0.1,
            generationDuration: 0.5, totalDuration: 0.6,
            renderedPrompt: "", rawText: "", embeddedChatTemplate: nil
        )
        let event = ServiceEvent.done(id: 1, result: result)
        let frame = try FrameCodec.encode(event)

        let pipe = Pipe()
        pipe.fileHandleForWriting.write(frame)
        pipe.fileHandleForWriting.closeFile()

        let decoded = try FrameCodec.decode(ServiceEvent.self, from: pipe.fileHandleForReading)
        #expect(decoded == event)
    }

    @Test("shutdown request round-trips (minimal payload)")
    func shutdownRoundTrip() throws {
        let request = ServiceRequest.shutdown
        let frame = try FrameCodec.encode(request)

        let pipe = Pipe()
        pipe.fileHandleForWriting.write(frame)
        pipe.fileHandleForWriting.closeFile()

        let decoded = try FrameCodec.decode(ServiceRequest.self, from: pipe.fileHandleForReading)
        #expect(decoded == .shutdown)
    }

    @Test("Frame header is 4-byte big-endian length")
    func frameHeaderFormat() throws {
        let request = ServiceRequest.shutdown
        let frame = try FrameCodec.encode(request)

        // First 4 bytes are the big-endian length of the JSON payload.
        let headerData = frame.prefix(4)
        let length = headerData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        #expect(Int(length) == frame.count - 4)

        // Remaining bytes are valid JSON.
        let payload = frame.dropFirst(4)
        let decoded = try JSONDecoder().decode(ServiceRequest.self, from: Data(payload))
        #expect(decoded == request)
    }

    // MARK: - Partial Reads / Reassembly

    @Test("Handles partial reads via reassembly")
    func partialReadReassembly() throws {
        let event = ServiceEvent.token(id: 1, piece: "Hello world")
        let frame = try FrameCodec.encode(event)

        // Write the frame in small chunks to simulate partial reads.
        let pipe = Pipe()
        let chunkSize = 3
        var offset = 0
        while offset < frame.count {
            let end = min(offset + chunkSize, frame.count)
            pipe.fileHandleForWriting.write(frame[offset ..< end])
            offset = end
        }
        pipe.fileHandleForWriting.closeFile()

        let decoded = try FrameCodec.decode(ServiceEvent.self, from: pipe.fileHandleForReading)
        #expect(decoded == event)
    }

    // MARK: - Coalesced Frames

    @Test("Decodes two coalesced frames sequentially")
    func coalescedFrames() throws {
        let event1 = ServiceEvent.token(id: 1, piece: "Hello")
        let event2 = ServiceEvent.token(id: 1, piece: " world")

        let frame1 = try FrameCodec.encode(event1)
        let frame2 = try FrameCodec.encode(event2)

        // Write both frames at once.
        let pipe = Pipe()
        pipe.fileHandleForWriting.write(frame1)
        pipe.fileHandleForWriting.write(frame2)
        pipe.fileHandleForWriting.closeFile()

        let decoded1 = try FrameCodec.decode(ServiceEvent.self, from: pipe.fileHandleForReading)
        let decoded2 = try FrameCodec.decode(ServiceEvent.self, from: pipe.fileHandleForReading)
        #expect(decoded1 == event1)
        #expect(decoded2 == event2)
    }

    @Test("Decodes many coalesced frames")
    func manyCoalescedFrames() throws {
        let pipe = Pipe()
        let count = 20
        var expected: [ServiceEvent] = []

        for i in 0 ..< count {
            let event = ServiceEvent.token(id: UInt64(i), piece: "token_\(i)")
            expected.append(event)
            let frame = try FrameCodec.encode(event)
            pipe.fileHandleForWriting.write(frame)
        }
        pipe.fileHandleForWriting.closeFile()

        for i in 0 ..< count {
            let decoded = try FrameCodec.decode(ServiceEvent.self, from: pipe.fileHandleForReading)
            #expect(decoded == expected[i])
        }
    }

    // MARK: - Oversize Frame Rejection

    @Test("Oversize length header throws oversizeFrame")
    func oversizeFrame() throws {
        // Construct a header with a length exceeding the 64 MB cap.
        let oversizeLength: UInt32 = FrameCodec.maxFrameSize + 1
        var header = oversizeLength.bigEndian
        let headerData = Data(bytes: &header, count: 4)

        let pipe = Pipe()
        pipe.fileHandleForWriting.write(headerData)
        pipe.fileHandleForWriting.closeFile()

        #expect(throws: FrameCodecError.self) {
            try FrameCodec.decode(ServiceEvent.self, from: pipe.fileHandleForReading)
        }
    }

    @Test("Oversize frame error carries the size")
    func oversizeFrameDetails() throws {
        let oversizeLength: UInt32 = FrameCodec.maxFrameSize + 100
        var header = oversizeLength.bigEndian
        let headerData = Data(bytes: &header, count: 4)

        let pipe = Pipe()
        pipe.fileHandleForWriting.write(headerData)
        pipe.fileHandleForWriting.closeFile()

        do {
            _ = try FrameCodec.decode(ServiceEvent.self, from: pipe.fileHandleForReading)
            Issue.record("Expected oversizeFrame error")
        } catch let error as FrameCodecError {
            #expect(error == .oversizeFrame(oversizeLength))
        }
    }

    @Test("Encode rejects payload exceeding maxFrameSize")
    func encodeOversizePayload() throws {
        // Create a value whose JSON encoding exceeds the 64 MB cap.
        // Use a string with enough content to push past the limit.
        let hugeString = String(repeating: "A", count: Int(FrameCodec.maxFrameSize) + 1)
        let event = ServiceEvent.token(id: 1, piece: hugeString)

        do {
            _ = try FrameCodec.encode(event)
            Issue.record("Expected oversizeFrame error")
        } catch let error as FrameCodecError {
            if case .oversizeFrame = error {
                // expected
            } else {
                Issue.record("Expected oversizeFrame, got \(error)")
            }
        }
    }

    // MARK: - Truncated Frame

    @Test("Truncated frame (EOF mid-payload) throws truncatedFrame")
    func truncatedFrame() throws {
        // Write a header promising 1000 bytes, but only provide 10.
        let promisedLength: UInt32 = 1000
        var header = promisedLength.bigEndian
        var data = Data(bytes: &header, count: 4)
        data.append(Data(repeating: 0x41, count: 10)) // only 10 bytes of 1000

        let pipe = Pipe()
        pipe.fileHandleForWriting.write(data)
        pipe.fileHandleForWriting.closeFile()

        #expect(throws: FrameCodecError.truncatedFrame) {
            try FrameCodec.decode(ServiceEvent.self, from: pipe.fileHandleForReading)
        }
    }

    @Test("Empty pipe (EOF before header) throws truncatedFrame")
    func emptyPipe() throws {
        let pipe = Pipe()
        pipe.fileHandleForWriting.closeFile()

        #expect(throws: FrameCodecError.truncatedFrame) {
            try FrameCodec.decode(ServiceEvent.self, from: pipe.fileHandleForReading)
        }
    }

    @Test("Partial header (only 2 bytes) throws truncatedFrame")
    func partialHeader() throws {
        let pipe = Pipe()
        pipe.fileHandleForWriting.write(Data([0x00, 0x00]))
        pipe.fileHandleForWriting.closeFile()

        #expect(throws: FrameCodecError.truncatedFrame) {
            try FrameCodec.decode(ServiceEvent.self, from: pipe.fileHandleForReading)
        }
    }

    // MARK: - Garbage / Invalid JSON

    @Test("Valid length but garbage JSON throws codecError")
    func garbageJSON() throws {
        let garbage = Data("not valid json at all".utf8)
        let length = UInt32(garbage.count)
        var header = length.bigEndian
        var frame = Data(bytes: &header, count: 4)
        frame.append(garbage)

        let pipe = Pipe()
        pipe.fileHandleForWriting.write(frame)
        pipe.fileHandleForWriting.closeFile()

        do {
            _ = try FrameCodec.decode(ServiceEvent.self, from: pipe.fileHandleForReading)
            Issue.record("Expected codecError")
        } catch let error as FrameCodecError {
            if case .codecError = error {
                // expected
            } else {
                Issue.record("Expected codecError, got \(error)")
            }
        }
    }

    // MARK: - Data Buffer Decode

    @Test("Data buffer decode returns nil when incomplete")
    func dataBufferIncomplete() throws {
        let event = ServiceEvent.ready
        let frame = try FrameCodec.encode(event)

        // Only provide part of the frame.
        let partial = frame.prefix(frame.count / 2)
        let result = try FrameCodec.decode(ServiceEvent.self, from: partial)
        #expect(result == nil)
    }

    @Test("Data buffer decode returns nil when less than 4 bytes")
    func dataBufferTooShort() throws {
        let data = Data([0x00, 0x00])
        let result = try FrameCodec.decode(ServiceEvent.self, from: data)
        #expect(result == nil)
    }

    @Test("Data buffer decode succeeds on complete frame")
    func dataBufferComplete() throws {
        let event = ServiceEvent.token(id: 5, piece: "test")
        let frame = try FrameCodec.encode(event)

        let result = try FrameCodec.decode(ServiceEvent.self, from: frame)
        #expect(result != nil)
        #expect(result!.value == event)
        #expect(result!.consumed == frame.count)
    }

    @Test("Data buffer decode reports correct consumed bytes with trailing data")
    func dataBufferWithTrailingData() throws {
        let event = ServiceEvent.ready
        let frame = try FrameCodec.encode(event)

        // Append extra bytes (start of another frame).
        var data = frame
        data.append(Data([0x00, 0x00, 0x00, 0x05]))

        let result = try FrameCodec.decode(ServiceEvent.self, from: data)
        #expect(result != nil)
        #expect(result!.value == .ready)
        #expect(result!.consumed == frame.count)
    }

    @Test("Data buffer decode rejects oversize frame")
    func dataBufferOversize() throws {
        let oversizeLength: UInt32 = FrameCodec.maxFrameSize + 1
        var header = oversizeLength.bigEndian
        let data = Data(bytes: &header, count: 4)

        #expect(throws: FrameCodecError.self) {
            try FrameCodec.decode(ServiceEvent.self, from: data)
        }
    }

    // MARK: - FrameCodecError

    @Test("FrameCodecError has descriptive messages")
    func errorDescriptions() {
        let errors: [FrameCodecError] = [
            .oversizeFrame(100_000_000),
            .truncatedFrame,
            .codecError("bad json"),
        ]
        for error in errors {
            #expect(error.errorDescription != nil)
            #expect(!error.errorDescription!.isEmpty)
        }
    }

    @Test("FrameCodecError equatable")
    func equatable() {
        #expect(FrameCodecError.truncatedFrame == FrameCodecError.truncatedFrame)
        #expect(FrameCodecError.oversizeFrame(100) == FrameCodecError.oversizeFrame(100))
        #expect(FrameCodecError.oversizeFrame(100) != FrameCodecError.oversizeFrame(200))
        #expect(FrameCodecError.codecError("a") == FrameCodecError.codecError("a"))
        #expect(FrameCodecError.truncatedFrame != FrameCodecError.codecError("x"))
    }
}
