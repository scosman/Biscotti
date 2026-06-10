import Foundation
import Testing
@testable import transcribe_cli
@testable import Transcription

// MARK: - JSON output formatting tests

@Suite("JSON output formatting")
struct JSONOutputFormattingTests {
    private func makeTestResult() -> TranscriptResult {
        TranscriptResult(
            id: UUID(uuidString: "12345678-1234-1234-1234-123456789ABC") ?? UUID(),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            transcriptionMethodId: "large-v3_turbo",
            language: "en",
            speakerCount: 2,
            segments: [
                TranscriptSegment(
                    speakerID: 0,
                    speakerLabel: "Speaker 0",
                    startTime: 0.0,
                    endTime: 2.5,
                    text: "Hello world",
                    confidence: 0.0,
                    noSpeechProbability: 0.02,
                    words: [
                        TranscriptWord(
                            word: "Hello", startTime: 0.0, endTime: 1.0,
                            probability: 0.95, speakerID: 0
                        ),
                        TranscriptWord(
                            word: "world", startTime: 1.0, endTime: 2.5,
                            probability: 0.88, speakerID: 0
                        )
                    ]
                )
            ],
            speakerEmbeddings: [:],
            processingDuration: 3.14
        )
    }

    @Test("JSON output is valid TranscriptResult")
    func jsonOutputIsValidTranscriptResult() throws {
        let result = makeTestResult()
        let jsonString = try formatResultJSON(result)
        let data = Data(jsonString.utf8)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(TranscriptResult.self, from: data)

        #expect(decoded.transcriptionMethodId == "large-v3_turbo")
        #expect(decoded.language == "en")
        #expect(decoded.speakerCount == 2)
        #expect(decoded.segments.count == 1)
        #expect(decoded.segments[0].text == "Hello world")
        #expect(decoded.processingDuration == 3.14)
    }

    @Test("JSON output uses ISO 8601 dates")
    func jsonOutputUsesISO8601Dates() throws {
        let result = makeTestResult()
        let jsonString = try formatResultJSON(result)

        // ISO 8601 date strings contain the 'T' separator and 'Z' suffix
        #expect(jsonString.contains("2023-11-14T"))
    }

    @Test("JSON output uses pretty print and sorted keys")
    func jsonOutputUsesPrettyPrintAndSortedKeys() throws {
        let result = makeTestResult()
        let jsonString = try formatResultJSON(result)

        // Pretty printed: has newlines and indentation
        #expect(jsonString.contains("\n"))
        #expect(jsonString.contains("  "))

        // Sorted keys: "createdAt" appears before "id" which appears before "language"
        let createdAtRange = try #require(jsonString.range(of: "\"createdAt\""))
        let idRange = try #require(jsonString.range(of: "\"id\""))
        let languageRange = try #require(jsonString.range(of: "\"language\""))
        #expect(createdAtRange.lowerBound < idRange.lowerBound)
        #expect(idRange.lowerBound < languageRange.lowerBound)
    }

    @Test("JSON output contains no diagnostics or non-JSON text")
    func jsonOutputIsPureJSON() throws {
        let result = makeTestResult()
        let jsonString = try formatResultJSON(result)

        // Must start with '{' and end with '}' (after trimming whitespace)
        let trimmed = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(trimmed.hasPrefix("{"))
        #expect(trimmed.hasSuffix("}"))

        // Must parse as valid JSON
        let data = Data(trimmed.utf8)
        let parsed = try JSONSerialization.jsonObject(with: data)
        #expect(parsed is [String: Any])
    }
}

// MARK: - Text output formatting tests

@Suite("Text output formatting")
struct TextOutputFormattingTests {
    private func makeTestResult() -> TranscriptResult {
        TranscriptResult(
            transcriptionMethodId: "large-v3_turbo",
            language: "en",
            speakerCount: 2,
            segments: [
                TranscriptSegment(
                    speakerID: 0,
                    speakerLabel: "Speaker 0",
                    startTime: 0.0,
                    endTime: 2.5,
                    text: "Hello world",
                    confidence: 0.0,
                    noSpeechProbability: 0.02,
                    words: [
                        TranscriptWord(
                            word: "Hello", startTime: 0.0, endTime: 1.0,
                            probability: 0.95, speakerID: 0
                        )
                    ]
                ),
                TranscriptSegment(
                    speakerID: 1,
                    speakerLabel: "Speaker 1",
                    startTime: 2.5,
                    endTime: 5.0,
                    text: "Good morning",
                    confidence: 0.0,
                    noSpeechProbability: 0.01,
                    words: nil
                )
            ],
            speakerEmbeddings: [:],
            processingDuration: 4.2
        )
    }

    @Test("Text output contains speaker labels")
    func textOutputContainsSpeakerLabels() {
        let result = makeTestResult()
        let text = formatResultText(result)
        #expect(text.contains("Speaker 0"))
        #expect(text.contains("Speaker 1"))
    }

    @Test("Text output contains timestamps")
    func textOutputContainsTimestamps() {
        let result = makeTestResult()
        let text = formatResultText(result)
        // Format: MM:SS.f -> MM:SS.f
        #expect(text.contains("00:00.0 -> 00:02.5"))
        #expect(text.contains("00:02.5 -> 00:05.0"))
    }

    @Test("Text output contains model and language info")
    func textOutputContainsMetadata() {
        let result = makeTestResult()
        let text = formatResultText(result)
        #expect(text.contains("large-v3_turbo"))
        #expect(text.contains("en"))
        #expect(text.contains("Speakers:   2"))
    }

    @Test("Text output contains word probabilities when present")
    func textOutputContainsWordProbabilities() {
        let result = makeTestResult()
        let text = formatResultText(result)
        #expect(text.contains("Hello(95%)"))
    }

    @Test("Text output contains transcript text")
    func textOutputContainsTranscriptText() {
        let result = makeTestResult()
        let text = formatResultText(result)
        #expect(text.contains("Hello world"))
        #expect(text.contains("Good morning"))
    }

    @Test("Text output includes speaker embeddings when present")
    func textOutputIncludesEmbeddings() {
        let result = TranscriptResult(
            transcriptionMethodId: "test",
            language: "en",
            speakerCount: 1,
            segments: [],
            speakerEmbeddings: [0: [0.1, 0.2, 0.3]],
            processingDuration: 0
        )
        let text = formatResultText(result)
        #expect(text.contains("Speaker 0: 3-dim vector"))
    }
}

// MARK: - OutputWriter inline stderr tests

@Suite("OutputWriter writeStderrInline")
struct OutputWriterInlineTests {
    @Test("writeStderrInline captures to stderrInlineWrites, not stdoutLines or stderrLines")
    func inlineWriteGoesToStderrOnly() {
        let writer = CapturingOutputWriter()

        writer.writeStderrInline(String(format: "\rDownload progress: %.0f%%", 50.0))
        writer.writeStderrInline(String(format: "\rDownload progress: %.0f%%", 100.0))

        #expect(writer.stderrInlineWrites.count == 2)
        #expect(writer.stderrInlineWrites[0] == "\rDownload progress: 50%")
        #expect(writer.stderrInlineWrites[1] == "\rDownload progress: 100%")

        // Must not leak into stdout or the newline-terminated stderr lines
        #expect(writer.stdoutLines.isEmpty)
        #expect(writer.stderrLines.isEmpty)
    }
}

// MARK: - File-existence pre-flight tests

@Suite("Audio path pre-flight validation")
struct AudioPathPreflightTests {
    @Test("Validation rejects a --mic path that does not exist")
    func micPathNotFound() throws {
        // Mic is checked before system, so a missing mic fails fast even with a valid system.
        let cli = try TranscribeCLI.parse([
            "--mic", "/nonexistent/audio.wav",
            "--system", "/usr/bin/true"
        ])
        let writer = CapturingOutputWriter()
        #expect(throws: (any Error).self) {
            try cli.validateAudioPaths(writer: writer)
        }
        #expect(writer.stderrText.contains("/nonexistent/audio.wav"))
        #expect(writer.stderrText.contains("--mic"))
    }

    @Test("Validation rejects a --system path that does not exist")
    func systemPathNotFound() throws {
        let cli = try TranscribeCLI.parse([
            "--mic", "/usr/bin/true",
            "--system", "/no/such/file.m4a"
        ])
        let writer = CapturingOutputWriter()
        #expect(throws: (any Error).self) {
            try cli.validateAudioPaths(writer: writer)
        }
        #expect(writer.stderrText.contains("/no/such/file.m4a"))
        #expect(writer.stderrText.contains("--system"))
    }

    @Test("Validation passes when both files exist on disk")
    func existingPathPasses() throws {
        let cli = try TranscribeCLI.parse([
            "--mic", "/usr/bin/true",
            "--system", "/usr/bin/true"
        ])
        let writer = CapturingOutputWriter()
        try cli.validateAudioPaths(writer: writer)
        #expect(writer.stderrLines.isEmpty)
    }
}
