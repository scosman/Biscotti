import Foundation
import SpeakerKit
import STTLabAnalysis
import STTLabCore
import WhisperKit

/// All loaded inputs for one meeting's analysis.
public struct MeetingInputs: Sendable {
    public var meetingID: String
    public var meta: MeetingMeta

    public var apple: EngineTranscript?
    public var whisper: EngineTranscript?
    public var reference: EngineTranscript?

    public var appleRunStats: RunStats?
    public var appleResult: AppleMeetingResult?
    public var whisperOutput: WhisperOutput?
    public var diarizationOutput: DiarizationOutput?
    public var referenceStatus: ReferenceStatus?

    /// Raw WhisperKit results for speaker alignment (Whisper uses these directly).
    public var whisperRaw: [TranscriptionResult]?
}

/// Loads saved engine outputs and builds neutral `EngineTranscript` per engine per meeting.
public enum AnalyzeInputs {

    /// Load all meeting inputs from the workspace and results directories.
    public static func load(
        workspace: URL,
        resultsDir: URL,
        manifest: BundleManifest,
        metas: [MeetingMeta]
    ) throws -> [MeetingInputs] {
        let homeDir = workspace.appendingPathComponent("home")

        var results: [MeetingInputs] = []

        for mid in manifest.meetings {
            guard let meta = metas.first(where: { $0.meetingID == mid }) else { continue }
            var inputs = MeetingInputs(meetingID: mid, meta: meta)

            // Apple results (from runner).
            let appleURL = resultsDir
                .appendingPathComponent("meetings/\(mid)/apple.json")
            if let appleResult: AppleMeetingResult = try? JSONFiles.read(from: appleURL) {
                inputs.appleResult = appleResult
                if appleResult.status == .completed {
                    let (words, stats) = AppleWordGrouper.group(
                        results: appleResult.results,
                        audioDuration: meta.durationSeconds
                    )
                    let displayText = appleResult.results.map(\.text).joined(separator: " ")
                    inputs.apple = EngineTranscript(
                        engine: .apple, words: words,
                        displayText: displayText
                    )
                    inputs.appleRunStats = stats
                }
            }

            // Whisper results (from home).
            let whisperURL = homeDir.appendingPathComponent("whisper/\(mid).json")
            if let whisperOut: WhisperOutput = try? JSONFiles.read(from: whisperURL) {
                inputs.whisperOutput = whisperOut
                if whisperOut.status == .completed, let rawResults = whisperOut.results {
                    inputs.whisperRaw = rawResults
                    let (words, displayText) = buildWhisperTranscript(rawResults)
                    inputs.whisper = EngineTranscript(
                        engine: .whisper, words: words,
                        displayText: displayText
                    )
                }
            }

            // Diarization (from home).
            let diaURL = homeDir.appendingPathComponent("diarization/\(mid).json")
            if let diaOut: DiarizationOutput = try? JSONFiles.read(from: diaURL) {
                inputs.diarizationOutput = diaOut
            }

            // Reference results (from home).
            let refDir = homeDir.appendingPathComponent("reference/\(mid)")
            let statusURL = refDir.appendingPathComponent("status.json")
            if let refStatus: ReferenceStatus = try? JSONFiles.read(from: statusURL) {
                inputs.referenceStatus = refStatus
                if refStatus.status == .completed {
                    let (words, displayText, hasWordTimes) = try buildReferenceTranscript(
                        refDir: refDir,
                        meta: meta
                    )
                    inputs.reference = EngineTranscript(
                        engine: .reference, words: words,
                        displayText: displayText, hasWordTimes: hasWordTimes
                    )
                }
            }

            results.append(inputs)
        }

        return results
    }

    // MARK: - Whisper transcript building

    /// Build EngineTranscript words from raw WhisperKit TranscriptionResults.
    public static func buildWhisperTranscript(
        _ results: [TranscriptionResult]
    ) -> (words: [EngineWord], displayText: String) {
        let specialTokenPattern = try! NSRegularExpression(pattern: #"^<\|.*\|>$"#)  // nonisolated(unsafe) not needed: local
        var words: [EngineWord] = []
        var segmentCounter = 0

        for result in results {
            for segment in result.segments {
                if let timings = segment.words {
                    for timing in timings {
                        let trimmed = timing.word.trimmingCharacters(
                            in: CharacterSet.whitespaces
                        )
                        if trimmed.isEmpty { continue }
                        let range = NSRange(trimmed.startIndex..., in: trimmed)
                        if specialTokenPattern.firstMatch(in: trimmed, range: range) != nil {
                            continue
                        }
                        words.append(EngineWord(
                            text: trimmed,
                            start: Double(timing.start),
                            end: Double(timing.end),
                            confidence: Double(timing.probability),
                            segmentIndex: segmentCounter
                        ))
                    }
                }
                segmentCounter += 1
            }
        }

        let displayText = words.map(\.text).joined(separator: " ")
        return (words, displayText)
    }

    // MARK: - Reference transcript building

    /// Build EngineTranscript words from saved reference chunk files.
    ///
    /// Chunk files use `chunk_s{start}_e{end}` naming (phase 3 deviation).
    /// Each chunk's offset comes from its meta `startSample`.
    public static func buildReferenceTranscript(
        refDir: URL,
        meta: MeetingMeta
    ) throws -> (words: [EngineWord], displayText: String, hasWordTimes: Bool) {
        let fm = FileManager.default

        // Find all meta files and sort by startSample.
        let contents = try fm.contentsOfDirectory(at: refDir, includingPropertiesForKeys: nil)
        let metaFiles = contents.filter { $0.lastPathComponent.hasSuffix(".meta.json") }

        var chunks: [(meta: ChunkMeta, responseURL: URL)] = []
        for metaURL in metaFiles {
            let chunkMeta: ChunkMeta = try JSONFiles.read(from: metaURL)
            let prefix = metaURL.lastPathComponent.replacingOccurrences(of: ".meta.json", with: "")
            let responseURL = refDir.appendingPathComponent("\(prefix).response.json")
            guard fm.fileExists(atPath: responseURL.path) else { continue }
            chunks.append((chunkMeta, responseURL))
        }

        chunks.sort { $0.meta.startSample < $1.meta.startSample }

        var words: [EngineWord] = []
        var textParts: [String] = []
        var hasWordTimes = true

        for (chunkIdx, chunk) in chunks.enumerated() {
            let offsetSeconds = Double(chunk.meta.startSample) / meta.sampleRate
            let body = try Data(contentsOf: chunk.responseURL)
            guard let response = try? JSONDecoder().decode(ReferenceResponse.self, from: body) else {
                continue
            }

            if let refWords = response.words, !refWords.isEmpty {
                for w in refWords {
                    // Find which segment this word belongs to (by midpoint).
                    let segIdx: Int
                    if let segs = response.segments {
                        let mid = (w.start + w.end) / 2
                        if let found = segs.firstIndex(where: { mid >= $0.start && mid <= $0.end }) {
                            segIdx = found
                        } else {
                            segIdx = chunkIdx + 10_000  // fallback per spec
                        }
                    } else {
                        segIdx = chunkIdx + 10_000
                    }

                    words.append(EngineWord(
                        text: w.word.trimmingCharacters(in: .whitespaces),
                        start: w.start + offsetSeconds,
                        end: w.end + offsetSeconds,
                        confidence: w.confidence,
                        segmentIndex: segIdx
                    ))
                }
                if let text = response.text {
                    textParts.append(text)
                } else {
                    textParts.append(refWords.map(\.word).joined(separator: " "))
                }
            } else {
                // No word-level times: split text into untimed words.
                hasWordTimes = false
                let text: String
                if let segs = response.segments {
                    text = segs.map(\.text).joined(separator: " ")
                } else {
                    text = response.text ?? ""
                }
                let splitWords = text.split(separator: " ", omittingEmptySubsequences: true)
                for w in splitWords {
                    words.append(EngineWord(
                        text: String(w).trimmingCharacters(in: .whitespaces),
                        segmentIndex: chunkIdx + 10_000
                    ))
                }
                textParts.append(text)
            }
        }

        let displayText = textParts.joined(separator: " ")
        return (words, displayText, hasWordTimes)
    }

    // MARK: - Engine status helpers

    /// Get the status string for a meeting's engine.
    public static func engineStatus(
        _ result: (any EngineResult)?,
        hasOutput: Bool
    ) -> String {
        guard hasOutput else { return "not run" }
        guard let r = result else { return "not run" }
        switch r.engineStatus {
        case .completed: return "completed"
        case .failed: return "failed"
        case .unsupportedLocale: return "unsupported locale"
        }
    }
}

/// Protocol to unify status extraction across engine result types.
public protocol EngineResult {
    var engineStatus: RunStatus { get }
}

extension AppleMeetingResult: EngineResult {
    public var engineStatus: RunStatus { status }
}

extension WhisperOutput: EngineResult {
    public var engineStatus: RunStatus { status }
}

extension ReferenceStatus: EngineResult {
    public var engineStatus: RunStatus { status }
}
