import Foundation

// Decides who said each word.
//
//  1. Source: compare the mic and system tracks under each word. Mic-loud
//     words are the user (their headset only hears them); system-loud words
//     are someone remote.
//  2. Remote words are named by whose speaking indicator was on at the time
//     (UI capture), allowing for the indicator lagging the audio.
//  3. Remote words with no indicator inherit a name through their
//     diarization cluster when that cluster was otherwise clearly one person.
//  4. Everything else keeps its diarization cluster ("Speaker N").

public struct FusionWord: Sendable, Equatable {
    public var text: String
    public var start: Double
    public var end: Double
    public var probability: Float
    public var clusterID: Int?

    public init(text: String, start: Double, end: Double, probability: Float = 1, clusterID: Int?) {
        self.text = text
        self.start = start
        self.end = end
        self.probability = probability
        self.clusterID = clusterID
    }
}

/// Per-frame loudness of both tracks, in dBFS.
public struct LevelTrack: Sendable, Equatable {
    public var frameSeconds: Double
    public var micDB: [Float]
    public var systemDB: [Float]

    public init(frameSeconds: Double, micDB: [Float], systemDB: [Float]) {
        self.frameSeconds = frameSeconds
        self.micDB = micDB
        self.systemDB = systemDB
    }

    /// Mean power over `[from, to]` in dB.
    func level(_ frames: [Float], from lower: Double, until upper: Double) -> Double {
        let first = max(0, Int(lower / frameSeconds))
        let last = min(frames.count, max(first + 1, Int((upper / frameSeconds).rounded(.up))))
        guard first < last else { return -180 }
        var sum = 0.0
        for index in first ..< last {
            sum += pow(10, Double(frames[index]) / 10)
        }
        return 10 * log10(sum / Double(last - first) + 1e-18)
    }
}

public enum WordSource: Sendable, Equatable {
    case mic, system, unknown
}

public enum FusedSpeaker: Sendable, Hashable {
    case user
    case person(String)
    case cluster(Int)
    case unknown
}

public struct FusedSegment: Sendable, Equatable {
    public var speaker: FusedSpeaker
    public var words: [FusionWord]

    public init(speaker: FusedSpeaker, words: [FusionWord]) {
        self.speaker = speaker
        self.words = words
    }

    public var start: Double {
        words.first?.start ?? 0
    }

    public var end: Double {
        words.last?.end ?? 0
    }

    public var text: String {
        words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The same rule as the transcript's "Unclear audio" flag,
    /// plus "[unintelligible]" placeholders.
    public var isUnclear: Bool {
        if words.contains(where: Unintelligible.isMarker) { return true }
        guard words.count >= 3 else { return false }
        let uncertain = words.count { $0.probability < 0.4 }
        let mean = words.reduce(Float(0)) { $0 + $1.probability } / Float(words.count)
        return uncertain >= 3 || mean < 0.6 || Double(uncertain) / Double(words.count) >= 0.3
    }

    public var meanProbability: Float {
        words.isEmpty ? 0 : words.reduce(Float(0)) { $0 + $1.probability } / Float(words.count)
    }
}

public struct FusionReport: Sendable, Equatable {
    public var hadLevels: Bool
    public var hadCapture: Bool
    public var participantsSeen: [String]
    public var userWords = 0
    public var namedWords = 0
    public var clusterWords = 0
    public var namedPeople: [String] = []
    /// Stretches of speech no words were transcribed for.
    public var unintelligibleLines = 0
    /// Words replaced by caption text.
    public var captionCorrections = 0
    /// Words dropped because they were said after the call.
    public var afterCallWords = 0
    /// Words dropped as the user's own voice echoed back.
    public var echoWords = 0

    public init(hadLevels: Bool, hadCapture: Bool, participantsSeen: [String]) {
        self.hadLevels = hadLevels
        self.hadCapture = hadCapture
        self.participantsSeen = participantsSeen
    }

    /// One line for the menu bar and logs.
    public var summary: String {
        var parts: [String] = []
        if hadLevels {
            parts.append("you: \(userWords) words")
        }
        if !namedPeople.isEmpty {
            parts.append("named \(namedPeople.joined(separator: ", "))")
        }
        if clusterWords > 0 {
            parts.append("\(clusterWords) words left to AI naming")
        }
        if unintelligibleLines > 0 {
            parts.append("\(unintelligibleLines) unintelligible")
        }
        if captionCorrections > 0 {
            parts.append("\(captionCorrections) words corrected from captions")
        }
        if afterCallWords > 0 {
            parts.append("dropped \(afterCallWords) words said after the call ended")
        }
        if echoWords > 0 {
            parts.append("dropped \(echoWords) words echoing you")
        }
        if !hadCapture {
            parts.append("no meeting-window capture")
        } else if participantsSeen.isEmpty {
            parts.append("capture saw no participants")
        }
        return parts.joined(separator: " · ")
    }
}

/// Who said one word: its caption, else the mic, else its
/// voice's name, else the voice.
struct WordNaming {
    let sources: [WordSource]
    let captioned: [Int: String]
    let userName: String
    let clusterNames: [Int: String]

    func speaker(at index: Int, word: FusionWord) -> FusedSpeaker {
        if let name = captioned[index] {
            return PersonName.same(name, userName) ? .user : .person(name)
        }
        if sources[index] == .mic {
            return .user
        }
        guard let cluster = word.clusterID else { return .unknown }
        return clusterNames[cluster].map(FusedSpeaker.person) ?? .cluster(cluster)
    }
}

public struct FusionResult: Sendable, Equatable {
    public var segments: [FusedSegment]
    public var report: FusionReport
    /// Person name -> how often the screen agreed while that voice spoke.
    public var evidence: [String: NameEvidence]
    /// Person name -> caption-matched words, for voices named by captions.
    public var captionEvidence: [String: Int]

    public init(
        segments: [FusedSegment], report: FusionReport, evidence: [String: NameEvidence] = [:],
        captionEvidence: [String: Int] = [:]
    ) {
        self.segments = segments
        self.report = report
        self.evidence = evidence
        self.captionEvidence = captionEvidence
    }
}

/// How well one voice's speech lined up with one person's highlight across
/// the whole meeting. Each turn (an unbroken run of that voice) is one
/// vote, so a person who talks 20 times and is highlighted each time
/// builds far more confidence than one short overlap.
public struct NameEvidence: Sendable, Equatable {
    public enum Strength: Sendable, Equatable {
        case weak, moderate, strong
    }

    /// Turns the voice took.
    public var turns: Int
    /// Turns where this person was the one highlighted.
    public var agreeingTurns: Int
    /// Turns where someone else was highlighted instead.
    public var conflictingTurns: Int

    public init(turns: Int, agreeingTurns: Int, conflictingTurns: Int) {
        self.turns = turns
        self.agreeingTurns = agreeingTurns
        self.conflictingTurns = conflictingTurns
    }

    public var agreement: Double {
        turns == 0 ? 0 : Double(agreeingTurns) / Double(turns)
    }

    /// Strong: 5+ agreeing turns and 60%+ of them, or 3+ with almost no
    /// disagreement. Moderate: 2+ agreeing turns and 35%+. Else weak.
    public var strength: Strength {
        let clean = conflictingTurns * 10 <= turns
        if agreeingTurns >= 5, agreement >= 0.6 { return .strong }
        if agreeingTurns >= 3, agreement >= 0.9, clean { return .strong }
        if agreeingTurns >= 2, agreement >= 0.35 { return .moderate }
        return .weak
    }

    /// "Highlighted on screen in 18 of 20 turns (someone else in 1)".
    public var summary: String {
        var text = "Highlighted on screen in \(agreeingTurns) of \(turns) turn\(turns == 1 ? "" : "s")"
        if conflictingTurns > 0 {
            text += " (someone else in \(conflictingTurns))"
        }
        return text
    }
}

public enum SpeakerFuser {
    public struct Tuning: Sendable {
        /// dB the louder track must win by to call a word.
        public var sourceMargin = 6.0
        /// Only the tail of a word is measured: Whisper starts are early.
        public var sourceWindow = 0.4
        /// Indicators trail the audio; widen each word by this much.
        public var leadSlack = 0.3
        public var lagSlack = 1.2
        /// A new line starts after this much silence.
        public var lineGap = 1.5
        /// A voice's turn ends after this much silence or when someone
        /// else speaks.
        public var turnGap = 1.0
        /// Turns shorter than this ("yeah", "mm") don't vote.
        public var minimumTurn = 0.4
        /// A highlight has to cover this share of a turn to vote.
        public var turnCoverage = 0.3
        public init() {}
    }

    public static func fuse(
        words: [FusionWord],
        levels: LevelTrack?,
        timeline: ParticipantTimeline?,
        userName: String,
        voiceSpans: [VoiceSpan] = [],
        tuning: Tuning = Tuning()
    ) -> FusionResult {
        // Captions correct words Whisper wasn't sure of.
        let afterCall = AfterCall.trim(
            words.sorted { $0.start < $1.start }, callEndedAt: timeline?.callEndedAt, levels: levels
        )
        let refined = CaptionAligner.refine(afterCall.words, captions: timeline?.captions ?? [])
        let sorted = refined.words
        let sources = classify(sorted, levels: levels, tuning: tuning)
        // Caption text says who said which words; it outranks
        // the loudness and highlight evidence below.
        let captioned = CaptionAligner.assign(sorted, captions: timeline?.captions ?? [])
        let captionNamed = captionNamedVoices(sorted, captioned: captioned, userName: userName)
        let naming = WordNaming(
            sources: sources, captioned: captioned, userName: userName,
            clusterNames: withCaptionNames(
                nameClusters(sorted, sources: sources, timeline: timeline ?? .empty, excluded: [userName], tuning: tuning),
                captionNamed: captionNamed
            )
        )
        let clusterNames = naming.clusterNames
        let named = sorted.indices.map { naming.speaker(at: $0, word: sorted[$0]) }
        let echoes = EchoFilter.echoes(sorted, speakers: named, sources: sources, captions: timeline?.captions ?? [], userName: userName)
        let kept = sorted.indices.filter { !echoes.contains($0) }
        var speakers = kept.map { named[$0] }
        // Speech diarization heard that Whisper couldn't make out becomes a
        // "[unintelligible]" line for whoever it was.
        var allWords = kept.map { sorted[$0] }
        let gaps = Unintelligible.find(
            spans: AfterCall.clip(voiceSpans, callEndedAt: afterCall.dropped > 0 ? timeline?.callEndedAt : nil),
            words: sorted, levels: levels
        )
        for (word, speaker) in unintelligibleLines(
            gaps, clusterNames: clusterNames, timeline: timeline, userName: userName
        ) {
            allWords.append(word)
            speakers.append(speaker)
        }
        let order = allWords.indices.sorted { allWords[$0].start < allWords[$1].start }
        let segments = group(order.map { allWords[$0] }, speakers: order.map { speakers[$0] }, gap: tuning.lineGap)

        var report = FusionReport(
            hadLevels: levels != nil, hadCapture: timeline != nil,
            participantsSeen: timeline?.participants ?? []
        )
        report.unintelligibleLines = segments.count { $0.words.contains(where: Unintelligible.isMarker) }
        report.captionCorrections = refined.replaced
        report.afterCallWords = afterCall.dropped
        report.echoWords = echoes.count
        report.count(speakers.prefix(kept.count))
        let evidence = turnEvidence(
            sorted, sources: sources, timeline: timeline ?? .empty, naming: ClusterNaming(names: clusterNames, excluded: [userName]), tuning: tuning
        )
        let captionEvidence = Dictionary(captionNamed.values.map { ($0.name, $0.words) }, uniquingKeysWith: max)
        return FusionResult(segments: segments, report: report, evidence: evidence, captionEvidence: captionEvidence)
    }

    // MARK: - Source

    /// Mic minus system level (dB) over the tail of each word.
    static func margins(_ words: [FusionWord], levels: LevelTrack, tuning: Tuning) -> [Double] {
        words.map { word in
            let lower = max(word.start, word.end - tuning.sourceWindow)
            let upper = max(word.end, lower + levels.frameSeconds)
            return levels.level(levels.micDB, from: lower, until: upper)
                - levels.level(levels.systemDB, from: lower, until: upper)
        }
    }

    static func classify(_ words: [FusionWord], levels: LevelTrack?, tuning: Tuning) -> [WordSource] {
        guard let levels else { return Array(repeating: .unknown, count: words.count) }
        let margin = margins(words, levels: levels, tuning: tuning)
        let collapsed = collapsedTimings(words)
        var sources = margin.enumerated().map { index, value -> WordSource in
            if collapsed[index] { return .unknown }
            if value > tuning.sourceMargin { return .mic }
            if value < -tuning.sourceMargin { return .system }
            return .unknown
        }
        keepRemoteVoicesRemote(&sources, words: words, margin: margin)
        fillFromNeighbours(&sources, words: words, collapsed: collapsed)
        fillCollapsed(&sources, words: words, collapsed: collapsed)
        return sources
    }

    /// Words whose timestamps the engine lost: zero length, or sharing a
    /// start time with a neighbour. Their loudness can't be measured.
    static func collapsedTimings(_ words: [FusionWord]) -> [Bool] {
        words.indices.map { index in
            let word = words[index]
            if word.end - word.start < 0.02 { return true }
            if index > 0, abs(words[index - 1].start - word.start) < 0.000_1 { return true }
            if index + 1 < words.count, abs(words[index + 1].start - word.start) < 0.000_1 { return true }
            return false
        }
    }

    /// A word with lost timing takes its voice's usual source, when that
    /// voice is at least 80% one source. Otherwise it stays unknown, which
    /// keeps it off the user (it is labelled by its voice instead).
    static func fillCollapsed(_ sources: inout [WordSource], words: [FusionWord], collapsed: [Bool]) {
        var mic: [Int: Int] = [:]
        var system: [Int: Int] = [:]
        for index in words.indices where !collapsed[index] {
            guard let cluster = words[index].clusterID else { continue }
            if sources[index] == .mic { mic[cluster, default: 0] += 1 }
            if sources[index] == .system { system[cluster, default: 0] += 1 }
        }
        for index in words.indices where collapsed[index] {
            guard let cluster = words[index].clusterID else { continue }
            let micCount = Double(mic[cluster] ?? 0)
            let systemCount = Double(system[cluster] ?? 0)
            let total = micCount + systemCount
            guard total >= 5 else { continue }
            if micCount / total >= 0.8 { sources[index] = .mic }
            if systemCount / total >= 0.8 { sources[index] = .system }
        }
    }

    // People talk over each other. A word that diarization put in a
    // clearly remote voice stays remote unless the mic is far louder (the
    // user laughing over someone shouldn't steal their words).

    static func keepRemoteVoicesRemote(_ sources: inout [WordSource], words: [FusionWord], margin: [Double]) {
        var mic: [Int: Int] = [:]
        var system: [Int: Int] = [:]
        for (index, word) in words.enumerated() {
            guard let cluster = word.clusterID else { continue }
            if sources[index] == .mic { mic[cluster, default: 0] += 1 }
            if sources[index] == .system { system[cluster, default: 0] += 1 }
        }
        for (index, word) in words.enumerated() where sources[index] == .mic {
            guard let cluster = word.clusterID else { continue }
            // A word that runs straight on from your own mic
            // speech is the rest of your sentence, even when a remote voice
            // overlaps it (2026-11-19 1:17, "You're | muted, Chris").
            if index > 0, sources[index - 1] == .mic, word.start - words[index - 1].end <= 0.35,
               !Self.endsSentence(words[index - 1].text) { continue }
            let remote = system[cluster] ?? 0
            let total = remote + (mic[cluster] ?? 0)
            if total >= 5, Double(remote) / Double(total) >= 0.7, margin[index] < 20 {
                sources[index] = .system
            }
        }
    }

    // MARK: - Names

    /// Each remote voice (diarization cluster) gets the participant whose
    /// indicator best follows it, one participant per voice, chosen so the
    /// whole meeting fits best. A voice with weak evidence keeps no name:
    /// a wrong name is worse than "Speaker 2".
    static func nameClusters(
        _ words: [FusionWord],
        sources: [WordSource],
        timeline: ParticipantTimeline,
        excluded: Set<String>,
        tuning: Tuning
    ) -> [Int: String] {
        guard !timeline.isEmpty else { return [:] }
        var covered: [Int: [String: Double]] = [:]
        var spoken: [Int: Double] = [:]
        for index in words.indices where sources[index] != .mic {
            let word = words[index]
            guard let cluster = word.clusterID else { continue }
            let lower = word.start - tuning.leadSlack
            let upper = word.end + tuning.lagSlack
            spoken[cluster, default: 0] += upper - lower
            for (name, seconds) in timeline.overlaps(from: lower, until: upper, excluding: excluded) {
                covered[cluster, default: [:]][name, default: 0] += seconds
            }
        }
        var scores: [Int: [String: Double]] = [:]
        for (cluster, seconds) in spoken {
            for (name, value) in covered[cluster] ?? [:] {
                scores[cluster, default: [:]][name] = value / max(seconds, 0.001)
            }
        }
        return assign(scores: scores, weights: spoken)
    }

    /// One participant per voice, maximising total score; pairs under 0.15
    /// are never made.
    static func assign(scores: [Int: [String: Double]], weights: [Int: Double]) -> [Int: String] {
        let clusters = weights.keys.sorted()
        let people = Set(scores.values.flatMap(\.keys)).sorted()
        guard !clusters.isEmpty, !people.isEmpty else { return [:] }
        func score(_ cluster: Int, _ person: String) -> Double {
            scores[cluster]?[person] ?? 0
        }
        guard clusters.count <= 6, people.count <= 6 else {
            var pairs: [Int: String] = [:]
            var used: Set<String> = []
            for cluster in clusters.sorted(by: { (weights[$0] ?? 0) > (weights[$1] ?? 0) }) {
                let open = people.filter { !used.contains($0) }
                guard let pick = open.max(by: { score(cluster, $0) < score(cluster, $1) }),
                      score(cluster, pick) >= 0.15 else { continue }
                pairs[cluster] = pick
                used.insert(pick)
            }
            return pairs
        }
        // Small exhaustive search: meetings have a handful of voices.
        var best: (total: Double, pairs: [Int: String]) = (0, [:])
        func search(_ index: Int, _ used: Set<String>, _ total: Double, _ pairs: [Int: String]) {
            if index == clusters.count {
                if total > best.total { best = (total, pairs) }
                return
            }
            let cluster = clusters[index]
            search(index + 1, used, total, pairs)
            for person in people where !used.contains(person) && score(cluster, person) >= 0.15 {
                var next = pairs
                next[cluster] = person
                search(index + 1, used.union([person]), total + score(cluster, person), next)
            }
        }
        search(0, [], 0, [:])
        return best.pairs
    }
}

// MARK: - Placeholders and lines

extension SpeakerFuser {
    /// The "[unintelligible]" placeholder words and who they belong to: the
    /// voice's name, else whoever's indicator was on, else the voice.
    static func unintelligibleLines(
        _ gaps: [Unintelligible.Gap], clusterNames: [Int: String], timeline: ParticipantTimeline?, userName: String
    ) -> [(FusionWord, FusedSpeaker)] {
        gaps.map { gap in
            let highlighted = timeline?.overlaps(from: gap.start, until: gap.end, excluding: [userName])
                .max(by: { $0.value < $1.value })?.key
            let speaker: FusedSpeaker = if gap.onMic {
                .user
            } else if let name = clusterNames[gap.cluster] ?? highlighted {
                .person(name)
            } else {
                .cluster(gap.cluster)
            }
            let word = FusionWord(
                text: " " + Unintelligible.marker, start: gap.start, end: gap.end, probability: 0,
                clusterID: gap.cluster == Unintelligible.unidentifiedCluster ? nil : gap.cluster
            )
            return (word, speaker)
        }
    }

    // MARK: - Lines

    static func group(_ words: [FusionWord], speakers: [FusedSpeaker], gap: Double) -> [FusedSegment] {
        var segments: [FusedSegment] = []
        for (index, word) in words.enumerated() {
            let speaker = speakers[index]
            // "[unintelligible]" always stands as its own line.
            let placeholder = Unintelligible.isMarker(word)
            let lastIsPlaceholder = segments.last?.words.first.map(Unintelligible.isMarker) ?? false
            if var last = segments.last, last.speaker == speaker, word.start - last.end <= gap,
               !placeholder, !lastIsPlaceholder
            {
                last.words.append(word)
                segments[segments.count - 1] = last
            } else {
                segments.append(FusedSegment(speaker: speaker, words: [word]))
            }
        }
        return segments
    }
}

// MARK: - Sources from neighbours, and the report

extension SpeakerFuser {
    /// An unsure word joins its neighbour in the same breath, but only a
    /// neighbour in the same voice: across a change of voice the neighbour
    /// says nothing about this word.
    static func fillFromNeighbours(_ sources: inout [WordSource], words: [FusionWord], collapsed: [Bool]) {
        // The next word with a known source, found in one backward pass.
        var nextKnown = [Int?](repeating: nil, count: sources.count)
        var upcoming: Int?
        for index in sources.indices.reversed() {
            nextKnown[index] = upcoming
            if sources[index] != .unknown { upcoming = index }
        }
        // A word with no voice (nil cluster) has no neighbour in its voice.
        for index in sources.indices where sources[index] == .unknown && !collapsed[index] && words[index].clusterID != nil {
            let word = words[index]
            if index > 0, sources[index - 1] != .unknown, words[index - 1].clusterID == word.clusterID,
               word.start - words[index - 1].end < 0.8
            {
                sources[index] = sources[index - 1]
            } else if let next = nextKnown[index], words[next].clusterID == word.clusterID,
                      words[next].start - word.end < 0.8
            {
                sources[index] = sources[next]
            }
        }
    }
}

extension FusionReport {
    /// Tallies who each spoken word went to.
    mutating func count(_ speakers: some Sequence<FusedSpeaker>) {
        for speaker in speakers {
            switch speaker {
            case .user: userWords += 1
            case let .person(name):
                namedWords += 1
                if !namedPeople.contains(name) { namedPeople.append(name) }
            case .cluster, .unknown: clusterWords += 1
            }
        }
    }
}
