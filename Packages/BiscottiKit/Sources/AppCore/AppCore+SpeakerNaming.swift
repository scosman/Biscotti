import AVFoundation
import DataStore
import Foundation
import os
import SpeakerFusion
import Transcription
import TranscriptionService
import UICapture

// After Whisper and diarization, rebuild the transcript with
// real speakers. The user's lines come from the mic track; remote voices are
// named from the meeting-window capture. Runs before AI enhancements, so the
// summary is written with the names. The engine's transcript is kept as the
// previous version.

private let namingLogger = Logger(subsystem: "net.scosman.biscotti", category: "SpeakerNaming")

extension AppCore {
    func installSpeakerNaming() {
        transcription.refiner = { [weak self] meetingID, result, vocabulary in
            await self?.refineSpeakers(meetingID: meetingID, result: result, vocabulary: vocabulary)
        }
    }

    func refineSpeakers(meetingID: UUID, result: TranscriptResult, vocabulary: [String] = []) async -> RefinedTranscript? {
        let settings = automation.settings
        guard settings.nameSpeakers else { return nil }
        let words = result.segments.flatMap { $0.words ?? [] }
        // No words but heard voices: the voices may still be re-listened to
        // as "[unintelligible]" lines below.
        guard !words.isEmpty || !result.speakerSpans.isEmpty else { return nil }

        let paths = try? await store.audioPaths(meetingID: meetingID)
        let detail = try? await store.meetingDetail(id: meetingID)
        let recordingStart = detail?.date ?? Date()
        let recordingEnd = recordingStart.addingTimeInterval(detail?.recordingDuration ?? words.last?.endTime ?? 0)
        let folders = [rootBundleFolder(meetingID: meetingID), uiCapture.folder, UICaptureController.defaultFolder]
            .compactMap(\.self)

        let (levels, timeline) = await Self.loadEvidence(
            audio: (paths?.mic, paths?.system), folders: folders,
            meetingID: meetingID, recordingStart: recordingStart, recordingEnd: recordingEnd
        )
        namingLogger.notice(
            "Speaker naming \(meetingID, privacy: .public): levels \(levels != nil, privacy: .public), capture \(timeline != nil, privacy: .public), \(timeline?.captions.count ?? 0, privacy: .public) captions"
        )
        MeetingEventLog.write(
            "naming",
            "Evidence: levels \(levels != nil), capture \(timeline != nil), \(timeline?.captions.count ?? 0) captions, participants \(timeline?.participants ?? [])",
            bundle: rootBundleFolder(meetingID: meetingID)
        )
        guard levels != nil || timeline != nil else {
            namingLogger.notice("Speaker naming skipped for \(meetingID, privacy: .public): no mic/system pair and no capture")
            return nil
        }
        let userName = settings.transcriptName.trimmingCharacters(in: .whitespaces).isEmpty
            ? NSFullUserName() : settings.transcriptName.trimmingCharacters(in: .whitespaces)
        await addSeenParticipants(Array(Set((timeline?.participants ?? []) + (timeline?.seen ?? []))), meetingID: meetingID, userName: userName)
        var fusion = SpeakerFuser.fuse(
            words: words.map {
                FusionWord(
                    text: $0.word, start: $0.startTime, end: $0.endTime,
                    probability: $0.probability, clusterID: $0.speakerID
                )
            },
            levels: levels,
            timeline: timeline,
            userName: userName,
            voiceSpans: result.speakerSpans.map { VoiceSpan(cluster: $0.speakerID, start: $0.start, end: $0.end) }
        )
        // Second pass with the meeting's names and terms: re-listen to unclear
        // lines with the vocabulary prompt, then fix name spelling.
        let pass = await secondPass(fusion.segments, paths: paths, vocabulary: vocabulary)
        fusion.segments = pass.segments
        guard !fusion.segments.isEmpty else { return nil }
        let title = detail?.title ?? "Meeting"
        let summary = [fusion.report.summary, pass.summary].filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
        automation.lastNamingReport = "\(title): \(summary)"
        namingLogger.notice("Speaker naming \(meetingID, privacy: .public): \(summary, privacy: .public)")
        MeetingEventLog.write("naming", "Result: \(summary)", bundle: rootBundleFolder(meetingID: meetingID))
        return Self.refined(from: fusion, original: result, userName: userName)
    }

    /// Converts fused lines back into a `TranscriptResult`. Speaker IDs: the
    /// user is 0, named people follow, unnamed voices come last.
    static func refined(from fusion: FusionResult, original: TranscriptResult, userName: String) -> RefinedTranscript {
        var ids: [FusedSpeaker: Int] = [:]
        var names: [Int: String] = [:]
        func id(for speaker: FusedSpeaker) -> Int? {
            if speaker == .unknown { return nil }
            if let known = ids[speaker] { return known }
            let next = ids.count
            ids[speaker] = next
            switch speaker {
            case .user: names[next] = userName
            case let .person(name): names[next] = name
            case .cluster, .unknown: break
            }
            return next
        }
        // Stable order: user, then people and voices by first appearance.
        if fusion.segments.contains(where: { $0.speaker == .user }) { _ = id(for: .user) }
        for segment in fusion.segments {
            if case .person = segment.speaker { _ = id(for: segment.speaker) }
        }
        var durations: [Int: TimeInterval] = [:]
        let segments = fusion.segments.map { segment -> TranscriptSegment in
            let speakerID = id(for: segment.speaker)
            if let speakerID { durations[speakerID, default: 0] += segment.end - segment.start }
            return transcriptSegment(segment, speakerID: speakerID)
        }
        var result = TranscriptResult(
            transcriptionMethodId: original.transcriptionMethodId,
            language: original.language,
            speakerCount: ids.count,
            segments: segments,
            embeddingSets: carriedVoiceprints(fusion: fusion, ids: ids, original: original),
            speakerSpeechDurations: durations,
            processingDuration: original.processingDuration
        )
        // Diarization's voice spans (in its own cluster numbers) stay
        // available to later passes, e.g. re-listening.
        result.speakerSpans = original.speakerSpans
        return RefinedTranscript(
            result: result, speakerNames: names,
            speakerProvenance: provenance(
                names: names, userName: userName, evidence: fusion.evidence, captionWords: fusion.captionEvidence
            )
        )
    }

    /// One fused line as a transcript segment for `speakerID`.
    static func transcriptSegment(_ segment: FusedSegment, speakerID: Int?) -> TranscriptSegment {
        TranscriptSegment(
            speakerID: speakerID,
            speakerLabel: speakerID.map { "Speaker \($0)" } ?? "Unknown",
            startTime: segment.start,
            endTime: segment.end,
            text: segment.text,
            confidence: segment.words.isEmpty ? 0
                : segment.words.reduce(Float(0)) { $0 + $1.probability } / Float(segment.words.count),
            noSpeechProbability: 0,
            words: segment.words.map {
                TranscriptWord(word: $0.text, startTime: $0.start, endTime: $0.end, probability: $0.probability, speakerID: speakerID)
            }
        )
    }

    /// Everyone the meeting window showed joins the meeting's
    /// attendees, invited or not (2026-11-19: Nora Hale and Jamie Ford
    /// were on the Fabrikam call but not the invite).
    func addSeenParticipants(_ names: [String], meetingID: UUID, userName: String) async {
        var ids: [UUID] = []
        for name in names where !PersonName.same(name, userName) {
            if let id = try? await store.findOrCreatePerson(name: name, email: nil) { ids.append(id) }
        }
        guard !ids.isEmpty, let added = try? await store.addParticipants(ids, to: meetingID), added > 0 else { return }
        MeetingEventLog.write("naming", "Added \(added) attendees seen in the meeting window", bundle: rootBundleFolder(meetingID: meetingID))
    }

    /// Loudness of both tracks and the meeting-window timeline, read off
    /// the main thread.
    nonisolated static func loadEvidence(
        audio: (mic: URL?, system: URL?), folders: [URL], meetingID: UUID, recordingStart: Date, recordingEnd: Date
    ) async -> (LevelTrack?, ParticipantTimeline?) {
        await Task.detached(priority: .utility) {
            var levels: LevelTrack?
            if let mic = audio.mic, let system = audio.system {
                levels = AudioLevelReader.levels(mic: mic, system: system)
            }
            var timeline: ParticipantTimeline?
            for folder in folders {
                guard let file = ParticipantTimelineBuilder.findCapture(
                    in: folder, meetingID: meetingID, recordingStart: recordingStart, recordingEnd: recordingEnd
                ) else { continue }
                timeline = try? ParticipantTimelineBuilder.build(captureFile: file, recordingStartedAt: recordingStart)
                break
            }
            return (levels, timeline)
        }.value
    }

    /// The badge for each name: your own voice comes from the microphone;
    /// everyone else from how many of their turns the screen agreed with.
    static func provenance(
        names: [Int: String], userName: String, evidence: [String: NameEvidence], captionWords: [String: Int] = [:]
    ) -> [Int: SpeakerNameProvenance] {
        var result: [Int: SpeakerNameProvenance] = [:]
        for (speakerID, name) in names {
            if speakerID == 0, name == userName {
                result[speakerID] = SpeakerNameProvenance(
                    source: .microphone, confidence: .high, detail: "Your microphone was the loudest source"
                )
            } else if let words = captionWords[name] {
                // Named by the meeting's live captions, not by highlights.
                result[speakerID] = SpeakerNameProvenance(
                    source: .screen, confidence: words >= 10 ? .high : .medium,
                    detail: "Named by the meeting's live captions (\(words) matching words)"
                )
            } else if let found = evidence[name] {
                let confidence: SpeakerNameConfidence = switch found.strength {
                case .strong: .high
                case .moderate: .medium
                case .weak: .low
                }
                result[speakerID] = SpeakerNameProvenance(source: .screen, confidence: confidence, detail: found.summary)
            } else {
                result[speakerID] = SpeakerNameProvenance(
                    source: .screen, confidence: .low,
                    detail: "Highlighted on screen only during unclear audio"
                )
            }
        }
        return result
    }
}

extension AppCore {
    /// Voice matching only reads the preferred transcript's voiceprints, so
    /// the refined transcript must carry them. A new speaker gets the
    /// diarization voiceprint of the voice it came from, but only when that
    /// voice is clearly theirs: at least 80% of the speaker's words came from
    /// it, and at least 80% of its words went to the speaker. Otherwise the
    /// speaker gets none rather than a mixed one.
    static func carriedVoiceprints(
        fusion: FusionResult, ids: [FusedSpeaker: Int], original: TranscriptResult
    ) -> [SpeakerEmbeddingSet] {
        var byPair: [Int: [Int: Int]] = [:] // new ID -> original cluster -> words
        // Every word of a voice and of a speaker counts in its total, even
        // words the other side doesn't have (an unnamed speaker, a word with
        // no voice), so a mixed voice can't look clean.
        var clusterTotals: [Int: Int] = [:]
        var speakerTotals: [Int: Int] = [:]
        for segment in fusion.segments {
            let newID = ids[segment.speaker]
            for word in segment.words {
                if let cluster = word.clusterID { clusterTotals[cluster, default: 0] += 1 }
                guard let newID else { continue }
                speakerTotals[newID, default: 0] += 1
                if let cluster = word.clusterID { byPair[newID, default: [:]][cluster, default: 0] += 1 }
            }
        }
        var source: [Int: Int] = [:] // new ID -> original cluster
        for (newID, clusters) in byPair {
            let total = speakerTotals[newID] ?? 0
            guard let top = clusters.max(by: { $0.value < $1.value }), total > 0,
                  Double(top.value) / Double(total) >= 0.8,
                  Double(top.value) / Double(clusterTotals[top.key] ?? top.value) >= 0.8
            else { continue }
            source[newID] = top.key
        }
        return original.embeddingSets.map { set in
            var vectors: [Int: [Float]] = [:]
            for (newID, cluster) in source {
                if let vector = set.vectors[cluster] { vectors[newID] = vector }
            }
            return SpeakerEmbeddingSet(kind: set.kind, space: set.space, vectors: vectors)
        }
    }
}

/// Loudness of the two recorded tracks in 50 ms frames.
enum AudioLevelReader {
    static let frameSeconds = 0.05

    static func levels(mic: URL, system: URL) -> LevelTrack? {
        guard let micDB = frames(mic), let systemDB = frames(system) else { return nil }
        return LevelTrack(frameSeconds: frameSeconds, micDB: micDB, systemDB: systemDB)
    }

    static func frames(_ url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let hop = AVAudioFrameCount(max(1, format.sampleRate * frameSeconds))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: hop * 200) else { return nil }
        var result: [Float] = []
        result.reserveCapacity(Int(Double(file.length) / Double(hop)) + 1)
        var sum: Double = 0
        var count = 0
        while true {
            do { try file.read(into: buffer) } catch { break }
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
            let channelCount = Int(format.channelCount)
            for frame in 0 ..< Int(buffer.frameLength) {
                var sample: Float = 0
                for channel in 0 ..< channelCount {
                    sample += channels[channel][frame]
                }
                sample /= Float(channelCount)
                sum += Double(sample * sample)
                count += 1
                if count == Int(hop) {
                    result.append(Float(10 * log10(sum / Double(count) + 1e-18)))
                    sum = 0
                    count = 0
                }
            }
        }
        if count > 0 { result.append(Float(10 * log10(sum / Double(count) + 1e-18))) }
        return result.isEmpty ? nil : result
    }
}
