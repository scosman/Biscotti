import Foundation
import SpeakerKit
import STTLabAnalysis
import STTLabCore
import Transcription
import WhisperKit

/// Bridges engine transcripts into WhisperKit types, runs SpeakerKit addSpeakerInfo,
/// applies the production assembly pipeline, and returns neutral AlignedTranscripts.
///
/// Architecture.md section 5 describes the design. The bridge step converts timed
/// EngineWords into TranscriptionResult/TranscriptionSegment/WordTiming so SpeakerKit
/// can process them. Untimed words are dropped (and counted).
public enum SpeakerAlignment {

    /// Align an engine transcript against a diarization, producing an AlignedTranscript.
    ///
    /// For Whisper, pass the raw `[TranscriptionResult]` as `whisperRaw` (the production input).
    /// For Apple and Reference, the words are bridged into WhisperKit types first.
    public static func align(
        _ transcript: EngineTranscript,
        whisperRaw: [TranscriptionResult]?,
        diarization: DiarizationResult,
        audioDuration: Double
    ) -> AlignedTranscript {
        let results: [TranscriptionResult]
        let dropped: Int

        if transcript.engine == .whisper, let raw = whisperRaw {
            results = raw
            dropped = 0
        } else {
            let bridged = bridge(transcript)
            results = bridged.results
            dropped = bridged.dropped
        }

        // Run SpeakerKit addSpeakerInfo (pure, no model loading).
        let speakerGroups = diarization.addSpeakerInfo(to: results, strategy: .subsegment)

        // Run production assembly pipeline:
        // SegmentBuilder copy -> TranscriptSanitizer.sanitize.
        let segments = productionAssembly(speakerGroups)
        let sanitized = TranscriptSanitizer.sanitize(segments, audioDuration: audioDuration)

        // Convert to AlignedTranscript.
        return toAligned(sanitized, engine: transcript.engine, droppedUntimedWords: dropped)
    }

    /// Bridge an EngineTranscript into WhisperKit TranscriptionResults.
    ///
    /// Groups timed words by segmentIndex (first-appearance order), builds
    /// TranscriptionSegment + WordTiming. Words without times are dropped.
    static func bridge(_ t: EngineTranscript) -> (results: [TranscriptionResult], dropped: Int) {
        // Group words by segmentIndex, preserving first-appearance order.
        var segmentOrder: [Int] = []
        var segmentWords: [Int: [EngineWord]] = [:]
        var dropped = 0

        for word in t.words {
            guard word.start != nil, word.end != nil else {
                dropped += 1
                continue
            }
            if segmentWords[word.segmentIndex] == nil {
                segmentOrder.append(word.segmentIndex)
            }
            segmentWords[word.segmentIndex, default: []].append(word)
        }

        var segments: [TranscriptionSegment] = []
        for (idx, segIdx) in segmentOrder.enumerated() {
            guard let words = segmentWords[segIdx], !words.isEmpty else { continue }

            let timings = words.map { w in
                WordTiming(
                    word: " " + w.text,
                    tokens: [],
                    start: Float(w.start!),
                    end: Float(w.end!),
                    probability: Float(w.confidence ?? 1.0)
                )
            }

            let text = words.map(\.text).joined(separator: " ")
            let segStart = Float(words.compactMap(\.start).min()!)
            let segEnd = Float(words.compactMap(\.end).max()!)

            let segment = TranscriptionSegment(
                id: idx,
                seek: 0,
                start: segStart,
                end: segEnd,
                text: text,
                tokens: [],
                temperature: 0,
                avgLogprob: 0,
                compressionRatio: 0,
                noSpeechProb: 0,
                words: timings
            )
            segments.append(segment)
        }

        let combinedText = segments.map(\.text).joined(separator: " ")
        let result = TranscriptionResult(
            text: combinedText,
            segments: segments,
            language: "en",
            timings: TranscriptionTimings()
        )

        return ([result], dropped)
    }

    // MARK: - Production assembly (copy of SegmentBuilder)

    // Copied from Packages/Transcription/Sources/Transcription/SegmentBuilder.swift
    // because SegmentBuilder is internal. This is the exact production path.
    static func productionAssembly(_ groups: [[SpeakerSegment]]) -> TranscriptResult {
        let segments = groups.flatMap { group in
            group.map(buildSegment)
        }
        return TranscriptResult(
            transcriptionMethodId: "sttlab",
            language: "en",
            speakerCount: 0,
            segments: segments,
            speakerEmbeddings: [:],
            processingDuration: 0
        )
    }

    // Copied from SegmentBuilder.buildSegment
    private static func buildSegment(from speakerSegment: SpeakerSegment) -> TranscriptSegment {
        let words: [TranscriptWord]? = speakerSegment.speakerWords.isEmpty ? nil :
            speakerSegment.speakerWords.map { swt in
                TranscriptWord(
                    word: swt.wordTiming.word,
                    startTime: TimeInterval(swt.wordTiming.start),
                    endTime: TimeInterval(swt.wordTiming.end),
                    probability: swt.wordTiming.probability,
                    speakerID: swt.speaker.speakerId
                )
            }

        let confidence: Float
        let noSpeechProb: Float
        if let transcription = speakerSegment.transcription {
            confidence = transcription.avgLogprob
            noSpeechProb = transcription.noSpeechProb
        } else {
            confidence = 0
            noSpeechProb = 0
        }

        return TranscriptSegment(
            speakerID: speakerSegment.speaker.speakerId,
            speakerLabel: speakerSegment.speaker.description,
            startTime: TimeInterval(speakerSegment.startTime),
            endTime: TimeInterval(speakerSegment.endTime),
            text: speakerSegment.text,
            confidence: confidence,
            noSpeechProbability: noSpeechProb,
            words: words
        )
    }

    // MARK: - Conversion to neutral AlignedTranscript

    static func toAligned(
        _ result: TranscriptResult,
        engine: EngineID,
        droppedUntimedWords: Int
    ) -> AlignedTranscript {
        var alignedSegments: [AlignedSegment] = []
        var alignedWords: [AlignedWord] = []

        for segment in result.segments {
            alignedSegments.append(AlignedSegment(
                speaker: segment.speakerID,
                start: segment.startTime,
                end: segment.endTime,
                text: segment.text,
                wordCount: segment.words?.count ?? 0
            ))

            if let words = segment.words {
                for w in words {
                    let trimmed = w.word.trimmingCharacters(in: .whitespaces)
                    alignedWords.append(AlignedWord(
                        word: EngineWord(
                            text: trimmed,
                            start: w.startTime,
                            end: w.endTime,
                            confidence: Double(w.probability),
                            segmentIndex: 0
                        ),
                        speaker: w.speakerID
                    ))
                }
            }
        }

        return AlignedTranscript(
            engine: engine,
            segments: alignedSegments,
            words: alignedWords,
            droppedUntimedWords: droppedUntimedWords
        )
    }
}
