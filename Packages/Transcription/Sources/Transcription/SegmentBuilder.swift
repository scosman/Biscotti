import Foundation
import SpeakerKit
import WhisperKit

/// Converts SpeakerKit's `[[SpeakerSegment]]` output into the library's
/// `[TranscriptSegment]` value type. Extracted from `InProcessTranscriptionEngine`
/// to keep type body length within lint limits.
enum SegmentBuilder {
    static func buildSegments(from groups: [[SpeakerSegment]]) -> [TranscriptSegment] {
        groups.flatMap { group in
            group.map(buildSegment)
        }
    }

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
}
