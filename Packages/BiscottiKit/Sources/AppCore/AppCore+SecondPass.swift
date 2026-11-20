import AVFoundation
import Foundation
import os
import SpeakerFusion
import Transcription

// A second pass after transcription.
//  1. Lines flagged unclear (and "[unintelligible]" ones) are cut out and
//     transcribed again on their own. On a short clip Whisper often does
//     better: on a test call it turned "Das ist das und verletzt" into "it
//     nodeware and blocked it" and recovered "I'm seeing 1670 entries" from
//     an unintelligible stretch. New words are kept only when Whisper is
//     clearly surer of them and the old line was really poor.
//     The vocabulary prompt is NOT used here: on all 20 test clips it
//     made Whisper return nothing at all.
//  2. Near misses of invite names are corrected in the text.

private let secondPassLogger = Logger(subsystem: "net.scosman.biscotti", category: "SpeakerNaming")

struct SecondPassResult {
    var segments: [FusedSegment]
    var relistened = 0
    var improved = 0
    var corrections: [NameCorrection] = []

    var summary: String {
        var parts: [String] = []
        if relistened > 0 {
            parts.append("re-listened to \(relistened) unclear, \(improved) clearer")
        }
        if !corrections.isEmpty {
            parts.append("fixed \(corrections.count) name spelling\(corrections.count == 1 ? "" : "s")")
        }
        return parts.joined(separator: " \u{00B7} ")
    }
}

extension AppCore {
    /// At most this many lines are re-listened to per meeting.
    static let maxRelistenClips = 30

    func secondPass(
        _ segments: [FusedSegment],
        paths: (mic: URL?, system: URL?)?,
        vocabulary: [String]
    ) async -> SecondPassResult {
        var result = SecondPassResult(segments: segments)
        let hints = vocabulary.filter { !$0.isEmpty && $0 != VocabularyPrompt.forceMarker }

        if let mic = paths?.mic, let system = paths?.system {
            let candidates = segments.indices.filter { segments[$0].isUnclear }.prefix(Self.maxRelistenClips)
            for index in candidates {
                result.relistened += 1
                if let better = await relisten(segments[index], mic: mic, system: system) {
                    result.segments[index] = better
                    result.improved += 1
                }
            }
        }

        for index in result.segments.indices {
            let corrected = HintCorrector.correct(result.segments[index].words, hints: hints)
            result.segments[index].words = corrected.words
            result.corrections += corrected.changes
        }
        for change in result.corrections {
            secondPassLogger.info(
                "Name fix at \(change.time, privacy: .public)s: \(change.original, privacy: .public) -> \(change.replacement, privacy: .public)"
            )
        }
        return result
    }

    /// Transcribes one line again on its own, from the track it was heard
    /// on. Returns the line with new words when they are clearly better.
    private func relisten(_ segment: FusedSegment, mic: URL, system: URL) async -> FusedSegment? {
        let start = max(0, segment.start - 0.3)
        let end = segment.end + 0.3
        let source = segment.speaker == .user ? mic : system
        guard let clip = AudioClipWriter.write(source, from: start, to: end) else { return nil }
        defer { try? FileManager.default.removeItem(at: clip) }

        let isUser = segment.speaker == .user
        let fresh: TranscriptResult
        do {
            fresh = try await transcription.transcribeClip(mic: isUser ? clip : nil, system: isUser ? nil : clip)
        } catch {
            secondPassLogger.error("Re-listen failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let cluster = segment.words.first?.clusterID
        let words = fresh.segments.flatMap { $0.words ?? [] }.map {
            FusionWord(
                text: $0.word, start: start + $0.startTime, end: start + $0.endTime,
                probability: $0.probability, clusterID: cluster
            )
        }
        guard Self.acceptRelisten(old: segment, new: words) else { return nil }
        var better = segment
        better.words = words
        return better
    }

    /// New words replace the old only when there are at least two, Whisper
    /// is clearly surer of them (60% and up, and 15 points better), and the
    /// old line was really poor: "[unintelligible]", under 60% overall, or
    /// drifted into another language. A merely so-so line keeps its words
    /// (a clip once turned "What happened to my glasses?" into a confident
    /// "Was I have in my glasses?").
    static func acceptRelisten(old: FusedSegment, new words: [FusionWord]) -> Bool {
        guard words.count >= 2 else { return false }
        let mean = words.reduce(Float(0)) { $0 + $1.probability } / Float(words.count)
        guard mean >= 0.6, mean >= old.meanProbability + 0.15 else { return false }
        let oldWasPoor = old.words.contains(where: { $0.text.contains("[unintelligible]") })
            || old.meanProbability < 0.6
            || LanguageDrift.looksForeign(old.words.map(\.text))
        return oldWasPoor && !LanguageDrift.looksForeign(words.map(\.text))
    }
}

/// Cuts a stretch of a recording into a temporary WAV file.
enum AudioClipWriter {
    static func write(_ source: URL, from start: Double, to end: Double) -> URL? {
        guard let file = try? AVAudioFile(forReading: source) else { return nil }
        let format = file.processingFormat
        let first = AVAudioFramePosition(start * format.sampleRate)
        let count = AVAudioFrameCount(max(0, (end - start) * format.sampleRate))
        guard first < file.length, count > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)
        else { return nil }
        file.framePosition = first
        guard (try? file.read(into: buffer, frameCount: count)) != nil else { return nil }

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("biscotti-clips", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(UUID().uuidString).wav")
        do {
            let output = try AVAudioFile(
                forWriting: url, settings: format.settings,
                commonFormat: format.commonFormat, interleaved: format.isInterleaved
            )
            try output.write(from: buffer)
        } catch {
            return nil
        }
        return url
    }
}
