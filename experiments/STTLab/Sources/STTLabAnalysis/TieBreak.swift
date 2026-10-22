/// Classification of a disagreement region.
public enum TieBreakClass: String, Codable, Sendable, CaseIterable {
    case appleMatches
    case whisperMatches
    case appleCloser
    case whisperCloser
    case tiedPartial
    case neither
}

/// A disagreement region between Apple and Whisper, with its reference classification.
public struct DisagreementRegion: Codable, Sendable {
    /// Half-open range in Whisper tokens.
    public var whisperRange: (start: Int, end: Int)
    /// Half-open range in Apple tokens.
    public var appleRange: (start: Int, end: Int)
    /// Half-open range in reference tokens (mapped from both sides).
    public var refRange: (start: Int, end: Int)
    /// Classification against the reference.
    public var classification: TieBreakClass
    /// Apple edit distance to the reference span.
    public var appleDistance: Int
    /// Whisper edit distance to the reference span.
    public var whisperDistance: Int
    /// Region size: max of apple and whisper token counts.
    public var size: Int
    /// Display texts for Apple, Whisper, Reference.
    public var appleText: String
    public var whisperText: String
    public var refText: String
    /// Time span from Apple words (seconds).
    public var appleTimeStart: Double?
    public var appleTimeEnd: Double?
    /// Time span from Whisper words (seconds).
    public var whisperTimeStart: Double?
    public var whisperTimeEnd: Double?
    /// Meeting ID (set during aggregation; nil for per-meeting regions).
    public var meetingID: String?

    // Codable conformance for tuples.
    enum CodingKeys: String, CodingKey {
        case whisperStart, whisperEnd, appleStart, appleEnd, refStart, refEnd
        case classification, appleDistance, whisperDistance, size
        case appleText, whisperText, refText
        case appleTimeStart, appleTimeEnd, whisperTimeStart, whisperTimeEnd
        case meetingID
    }

    public init(whisperRange: (Int, Int), appleRange: (Int, Int), refRange: (Int, Int),
                classification: TieBreakClass, appleDistance: Int, whisperDistance: Int,
                size: Int, appleText: String, whisperText: String, refText: String,
                appleTimeStart: Double? = nil, appleTimeEnd: Double? = nil,
                whisperTimeStart: Double? = nil, whisperTimeEnd: Double? = nil,
                meetingID: String? = nil) {
        self.whisperRange = whisperRange
        self.appleRange = appleRange
        self.refRange = refRange
        self.classification = classification
        self.appleDistance = appleDistance
        self.whisperDistance = whisperDistance
        self.size = size
        self.appleText = appleText
        self.whisperText = whisperText
        self.refText = refText
        self.appleTimeStart = appleTimeStart
        self.appleTimeEnd = appleTimeEnd
        self.whisperTimeStart = whisperTimeStart
        self.whisperTimeEnd = whisperTimeEnd
        self.meetingID = meetingID
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        whisperRange = (try c.decode(Int.self, forKey: .whisperStart),
                        try c.decode(Int.self, forKey: .whisperEnd))
        appleRange = (try c.decode(Int.self, forKey: .appleStart),
                      try c.decode(Int.self, forKey: .appleEnd))
        refRange = (try c.decode(Int.self, forKey: .refStart),
                    try c.decode(Int.self, forKey: .refEnd))
        classification = try c.decode(TieBreakClass.self, forKey: .classification)
        appleDistance = try c.decode(Int.self, forKey: .appleDistance)
        whisperDistance = try c.decode(Int.self, forKey: .whisperDistance)
        size = try c.decode(Int.self, forKey: .size)
        appleText = try c.decode(String.self, forKey: .appleText)
        whisperText = try c.decode(String.self, forKey: .whisperText)
        refText = try c.decode(String.self, forKey: .refText)
        appleTimeStart = try c.decodeIfPresent(Double.self, forKey: .appleTimeStart)
        appleTimeEnd = try c.decodeIfPresent(Double.self, forKey: .appleTimeEnd)
        whisperTimeStart = try c.decodeIfPresent(Double.self, forKey: .whisperTimeStart)
        whisperTimeEnd = try c.decodeIfPresent(Double.self, forKey: .whisperTimeEnd)
        meetingID = try c.decodeIfPresent(String.self, forKey: .meetingID)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(whisperRange.start, forKey: .whisperStart)
        try c.encode(whisperRange.end, forKey: .whisperEnd)
        try c.encode(appleRange.start, forKey: .appleStart)
        try c.encode(appleRange.end, forKey: .appleEnd)
        try c.encode(refRange.start, forKey: .refStart)
        try c.encode(refRange.end, forKey: .refEnd)
        try c.encode(classification, forKey: .classification)
        try c.encode(appleDistance, forKey: .appleDistance)
        try c.encode(whisperDistance, forKey: .whisperDistance)
        try c.encode(size, forKey: .size)
        try c.encode(appleText, forKey: .appleText)
        try c.encode(whisperText, forKey: .whisperText)
        try c.encode(refText, forKey: .refText)
        try c.encodeIfPresent(appleTimeStart, forKey: .appleTimeStart)
        try c.encodeIfPresent(appleTimeEnd, forKey: .appleTimeEnd)
        try c.encodeIfPresent(whisperTimeStart, forKey: .whisperTimeStart)
        try c.encodeIfPresent(whisperTimeEnd, forKey: .whisperTimeEnd)
        try c.encodeIfPresent(meetingID, forKey: .meetingID)
    }
}

/// Tie-break counts, both by region count and by token weight.
public struct TieBreakCounts: Codable, Sendable, Equatable {
    public var byRegion: [String: Int]
    public var byTokens: [String: Int]

    public init(byRegion: [String: Int] = [:], byTokens: [String: Int] = [:]) {
        self.byRegion = byRegion
        self.byTokens = byTokens
    }
}

/// Disagreement analysis between Apple and Whisper, tied-broke against a reference.
public enum TieBreak {

    /// A raw disagreement region before reference scoring.
    struct RawRegion {
        var whisperRange: (start: Int, end: Int)
        var appleRange: (start: Int, end: Int)
    }

    /// Compute disagreement regions and classify each against the reference.
    ///
    /// - Parameters:
    ///   - appleTokens: Normalized tokens from Apple.
    ///   - whisperTokens: Normalized tokens from Whisper.
    ///   - refTokens: Normalized tokens from the reference.
    ///   - appleWords: Source engine words (for display text and times).
    ///   - whisperWords: Source engine words (for display text and times).
    ///   - refWords: Source engine words (for display text).
    /// - Returns: The regions with classifications, and aggregate counts.
    public static func analyze(
        appleTokens: [NormToken], whisperTokens: [NormToken], refTokens: [NormToken],
        appleWords: [EngineWord], whisperWords: [EngineWord], refWords: [EngineWord]
    ) -> (regions: [DisagreementRegion], counts: TieBreakCounts) {

        let aTexts = appleTokens.map(\.text)
        let wTexts = whisperTokens.map(\.text)
        let rTexts = refTokens.map(\.text)

        // Align Apple vs Whisper (Whisper = a, Apple = b in the alignment).
        let opsAW = Aligner.align(wTexts, aTexts)
        // Align Reference vs Apple, Reference vs Whisper.
        let opsRA = Aligner.align(rTexts, aTexts)
        let opsRW = Aligner.align(rTexts, wTexts)

        // Step 1: Extract raw disagreement regions from opsAW.
        let rawRegions = extractRegionsDirect(opsAW)

        // Step 2: Build mapping arrays from ref to apple/whisper and vice versa.
        let refOfA = buildRefMap(opsRA)
        let refOfW = buildRefMap(opsRW)
        let insertPointA = buildInsertPointMap(opsRA, refCount: rTexts.count)
        let insertPointW = buildInsertPointMap(opsRW, refCount: rTexts.count)

        // Step 3-5: Score each region.
        var regions: [DisagreementRegion] = []
        var countByRegion: [String: Int] = [:]
        var countByTokens: [String: Int] = [:]

        for raw in rawRegions {
            let (a0, a1) = raw.appleRange
            let (w0, w1) = raw.whisperRange

            // Map to reference span.
            let refSpan = mapToRefSpan(
                appleRange: a0..<a1, whisperRange: w0..<w1,
                refOfA: refOfA, refOfW: refOfW,
                insertPointA: insertPointA, insertPointW: insertPointW
            )

            let rSlice = refSpan.isEmpty ? [] : Array(rTexts[refSpan.lowerBound..<refSpan.upperBound])
            let aSlice = a0 < a1 ? Array(aTexts[a0..<a1]) : []
            let wSlice = w0 < w1 ? Array(wTexts[w0..<w1]) : []

            // Edit distance of each side to the reference span.
            let eA = editDistance(aSlice, rSlice)
            let eW = editDistance(wSlice, rSlice)

            // Common tokens (matches in the alignment of each side vs reference span).
            let commonA = countMatches(aSlice, rSlice)
            let commonW = countMatches(wSlice, rSlice)

            // Classify.
            let cls: TieBreakClass
            if eA == 0 {
                cls = .appleMatches
            } else if eW == 0 {
                cls = .whisperMatches
            } else if eA < eW {
                cls = .appleCloser
            } else if eW < eA {
                cls = .whisperCloser
            } else if commonA + commonW > 0 {
                cls = .tiedPartial
            } else {
                cls = .neither
            }

            let regionSize = max(a1 - a0, w1 - w0)

            // Display texts from source words.
            let aDisplay = displayText(tokens: appleTokens, range: a0..<a1, words: appleWords)
            let wDisplay = displayText(tokens: whisperTokens, range: w0..<w1, words: whisperWords)
            let rDisplay = displayText(tokens: refTokens, range: refSpan, words: refWords)

            // Time spans.
            let aTimes = timeSpan(tokens: appleTokens, range: a0..<a1, words: appleWords)
            let wTimes = timeSpan(tokens: whisperTokens, range: w0..<w1, words: whisperWords)

            regions.append(DisagreementRegion(
                whisperRange: (w0, w1), appleRange: (a0, a1),
                refRange: (refSpan.lowerBound, refSpan.upperBound),
                classification: cls, appleDistance: eA, whisperDistance: eW,
                size: regionSize,
                appleText: aDisplay, whisperText: wDisplay, refText: rDisplay,
                appleTimeStart: aTimes?.0, appleTimeEnd: aTimes?.1,
                whisperTimeStart: wTimes?.0, whisperTimeEnd: wTimes?.1
            ))

            countByRegion[cls.rawValue, default: 0] += 1
            countByTokens[cls.rawValue, default: 0] += regionSize
        }

        let counts = TieBreakCounts(byRegion: countByRegion, byTokens: countByTokens)
        return (regions, counts)
    }

    /// Sample regions for the report: 15 largest + 15 random (seeded).
    public static func sample(_ regions: [DisagreementRegion],
                              largestCount: Int = 15,
                              randomCount: Int = 15,
                              seed: UInt64 = 42) -> [DisagreementRegion] {
        let sorted = regions.sorted { $0.size > $1.size }
        let largest = Array(sorted.prefix(largestCount))
        let largestSet = Set(0..<min(largestCount, sorted.count))

        let rest = sorted.enumerated().compactMap { idx, r in
            largestSet.contains(idx) ? nil : r
        }

        var rng = SplitMix64(seed: seed)
        let sampled = sampleWithoutReplacement(rest, count: randomCount, rng: &rng)

        return largest + sampled
    }

    // MARK: - Region extraction

    /// Walk ops to find disagreement regions, merging runs separated by a single match.
    static func extractRegionsDirect(_ ops: [EditOp]) -> [RawRegion] {
        // Identify runs of non-match ops, merging runs separated by a single match.
        struct Span {
            var wMin: Int?
            var wMax: Int?
            var aMin: Int?
            var aMax: Int?

            mutating func addW(_ i: Int) {
                wMin = min(wMin ?? i, i)
                wMax = max((wMax ?? i), i)
            }
            mutating func addA(_ i: Int) {
                aMin = min(aMin ?? i, i)
                aMax = max((aMax ?? i), i)
            }
            var whisperRange: (Int, Int) { (wMin ?? 0, (wMax ?? -1) + 1) }
            var appleRange: (Int, Int) { (aMin ?? 0, (aMax ?? -1) + 1) }
        }

        var regions: [RawRegion] = []
        var current: Span?
        var matchAfterRegion: (Int, Int)? // (w, a) of a single match following a region

        for op in ops {
            switch op {
            case .match(let wi, let ai):
                if current != nil {
                    if matchAfterRegion == nil {
                        // First match after a disagreement: hold it.
                        matchAfterRegion = (wi, ai)
                    } else {
                        // Second match: finalize the region.
                        if let c = current {
                            regions.append(RawRegion(
                                whisperRange: c.whisperRange,
                                appleRange: c.appleRange
                            ))
                        }
                        current = nil
                        matchAfterRegion = nil
                    }
                }

            case .sub(let wi, let ai):
                if matchAfterRegion != nil {
                    // Merge: that single match is absorbed into the region.
                    matchAfterRegion = nil
                }
                if current == nil { current = Span() }
                current?.addW(wi)
                current?.addA(ai)

            case .del(let wi):
                if matchAfterRegion != nil { matchAfterRegion = nil }
                if current == nil { current = Span() }
                current?.addW(wi)

            case .ins(let ai):
                if matchAfterRegion != nil { matchAfterRegion = nil }
                if current == nil { current = Span() }
                current?.addA(ai)
            }
        }

        if let c = current {
            regions.append(RawRegion(
                whisperRange: c.whisperRange,
                appleRange: c.appleRange
            ))
        }

        return regions
    }

    // MARK: - Reference mapping

    /// Build refOfX[i] -> ref index for match/sub ops.
    static func buildRefMap(_ opsRX: [EditOp]) -> [Int: Int] {
        var map: [Int: Int] = [:]
        for op in opsRX {
            switch op {
            case .match(let ri, let xi), .sub(let ri, let xi):
                map[xi] = ri
            default: break
            }
        }
        return map
    }

    /// Build insertPointX[i] -> the ref index of the next aligned token after position i.
    static func buildInsertPointMap(_ opsRX: [EditOp], refCount: Int) -> [Int: Int] {
        var map: [Int: Int] = [:]
        // Walk ops in reverse to find the next ref-aligned position after each insertion.
        var nextRef = refCount
        for op in opsRX.reversed() {
            switch op {
            case .match(let ri, _), .sub(let ri, _):
                nextRef = ri
            case .ins(let xi):
                map[xi] = nextRef
            case .del:
                break
            }
        }
        return map
    }

    /// Map an apple/whisper region to a reference span.
    static func mapToRefSpan(
        appleRange: Range<Int>, whisperRange: Range<Int>,
        refOfA: [Int: Int], refOfW: [Int: Int],
        insertPointA: [Int: Int], insertPointW: [Int: Int]
    ) -> Range<Int> {
        var refIndices: [Int] = []

        for i in appleRange {
            if let ri = refOfA[i] { refIndices.append(ri) }
            else if let ip = insertPointA[i] { refIndices.append(ip) }
        }
        for i in whisperRange {
            if let ri = refOfW[i] { refIndices.append(ri) }
            else if let ip = insertPointW[i] { refIndices.append(ip) }
        }

        guard let lo = refIndices.min(), let hi = refIndices.max() else {
            // No mapping found; return an empty range at 0.
            return 0..<0
        }

        // For matched indices, use [min, max+1); for insert points, the point itself is a boundary.
        // Determine if hi is from a match (needs +1) or an insert point (boundary).
        let hiIsMatch = (appleRange.contains(where: { refOfA[$0] == hi })
                         || whisperRange.contains(where: { refOfW[$0] == hi }))
        return lo..<(hiIsMatch ? hi + 1 : hi)
    }

    // MARK: - Edit distance helpers

    /// Compute edit distance between two small token arrays.
    static func editDistance(_ a: [String], _ b: [String]) -> Int {
        if a.count + b.count > 400 {
            return Aligner.cost(Aligner.align(a, b))
        }
        return Aligner.cost(Aligner.alignNaive(a, b))
    }

    /// Count matches between two small token arrays.
    static func countMatches(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty || b.isEmpty { return 0 }
        let ops: [EditOp]
        if a.count + b.count > 400 {
            ops = Aligner.align(a, b)
        } else {
            ops = Aligner.alignNaive(a, b)
        }
        return Aligner.opCounts(ops).matches
    }

    // MARK: - Display text and time span helpers

    /// Get display text for a token range by looking up source words.
    static func displayText(tokens: [NormToken], range: Range<Int>,
                            words: [EngineWord]) -> String {
        if range.isEmpty { return "" }
        // Collect unique source indices in order.
        var seen = Set<Int>()
        var indices: [Int] = []
        for i in range {
            let si = tokens[i].sourceIndex
            if seen.insert(si).inserted { indices.append(si) }
        }
        return indices.map { words[$0].text }.joined(separator: " ")
    }

    /// Get the time span for a token range.
    static func timeSpan(tokens: [NormToken], range: Range<Int>,
                         words: [EngineWord]) -> (Double, Double)? {
        if range.isEmpty { return nil }
        var minStart: Double?
        var maxEnd: Double?
        for i in range {
            let w = words[tokens[i].sourceIndex]
            if let s = w.start {
                minStart = min(minStart ?? s, s)
            }
            if let e = w.end {
                maxEnd = max(maxEnd ?? e, e)
            }
        }
        guard let s = minStart, let e = maxEnd else { return nil }
        return (s, e)
    }

}

// MARK: - SplitMix64 RNG

/// A simple, deterministic PRNG for reproducible sampling.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }
}

/// Fisher-Yates sample without replacement.
func sampleWithoutReplacement<T>(_ array: [T], count: Int,
                                  rng: inout SplitMix64) -> [T] {
    var pool = array
    let n = min(count, pool.count)
    for i in 0..<n {
        let j = i + Int(rng.next() % UInt64(pool.count - i))
        pool.swapAt(i, j)
    }
    return Array(pool.prefix(n))
}
