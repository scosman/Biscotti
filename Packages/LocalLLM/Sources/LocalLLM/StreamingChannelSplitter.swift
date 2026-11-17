/// An incremental channel splitter that classifies raw token pieces into content
/// vs reasoning, detecting `OutputParser.thinkingOpenTag` and `thinkingCloseTag`
/// markers that may span multiple tokens.
///
/// Tokens are fed one at a time via `feed(_:)`. The splitter withholds a small
/// tail buffer (at least as long as the longest marker) until a marker is matched
/// or definitively ruled out, then releases classified pieces. Call `finish()` at
/// stream end to flush any withheld buffer.
///
/// `generatedTokenCount` tracks the total tokens fed (reasoning is a routing of
/// the same token stream, not a separate count).
///
/// Reuses `OutputParser.thinkingOpenTag` / `.thinkingCloseTag` as the single
/// source of truth for marker strings.
///
/// With reasoning suppressed, a bare close tag that arrives before any other marker
/// is treated as the end of plain-text reasoning (see
/// `OutputParser.dropThroughBareThinkingClose`): the marker and any text still
/// withheld before it are dropped. Text already released cannot be recalled, so the
/// final `GenerationResult.text` is the authoritative cleaned output.
public struct StreamingChannelSplitter: Sendable {
    /// Which channel the splitter is currently in.
    private enum State {
        case content
        case reasoning
    }

    /// A classified piece of output.
    public enum Piece: Sendable, Equatable {
        case content(String)
        case reasoning(String)
    }

    /// Whether to suppress reasoning output entirely (ThinkingMode.off).
    public let suppressReasoning: Bool

    private var state: State = .content
    /// Whether any marker (open, close, or bare close) has been consumed yet.
    private var sawMarker = false
    /// Buffer of unclassified text that might contain a partial marker.
    private var buffer: String = ""

    private static let openTag = OutputParser.thinkingOpenTag
    private static let closeTag = OutputParser.thinkingCloseTag
    /// The minimum buffer length before we can be sure no marker is partially present.
    private static let maxMarkerLength = max(openTag.count, closeTag.count)

    /// Create a splitter.
    ///
    /// - Parameter suppressReasoning: When true (ThinkingMode.off), reasoning
    ///   content and markers are silently dropped. When false (ThinkingMode.auto),
    ///   reasoning content is emitted as `.reasoning` pieces.
    public init(suppressReasoning: Bool) {
        self.suppressReasoning = suppressReasoning
    }

    /// Feed a raw token piece into the splitter.
    ///
    /// Returns zero or more classified pieces that can be released to the consumer.
    /// Pieces are returned in order; the caller should emit them sequentially.
    public mutating func feed(_ token: String) -> [Piece] {
        buffer += token
        return drain()
    }

    /// Flush any remaining buffer at stream end.
    ///
    /// After this call, the splitter should not be used further.
    public mutating func finish() -> [Piece] {
        // Flush everything remaining in the buffer.
        var pieces: [Piece] = []
        if !buffer.isEmpty {
            pieces.append(contentsOf: emitBuffer(buffer))
            buffer = ""
        }
        return pieces
    }

    // MARK: - Internal

    /// Drain the buffer, releasing as many classified pieces as possible while
    /// withholding enough tail to detect a partial marker.
    private mutating func drain() -> [Piece] {
        var pieces: [Piece] = []

        while !buffer.isEmpty {
            let markers = currentMarkers()

            // Check for a complete marker match (earliest in the buffer wins).
            if let match = earliestMatch(of: markers) {
                let prefix = String(buffer[..<match.range.lowerBound])
                // Consume the marker (strip it from output).
                buffer = String(buffer[match.range.upperBound...])
                sawMarker = true

                if state == .content, match.marker == Self.closeTag {
                    // Bare close: the withheld prefix is reasoning; drop it.
                    continue
                }

                // Everything before the marker belongs to the current channel.
                if !prefix.isEmpty {
                    pieces.append(contentsOf: emitBuffer(prefix))
                }

                // Transition state.
                switch state {
                case .content:
                    state = .reasoning
                case .reasoning:
                    state = .content
                }

                // Continue draining — there might be more markers or content.
                continue
            }

            // Check if a marker could be partially present at the tail.
            if markers.contains(where: { hasPotentialPartialMarker($0) }) {
                // Release everything up to the potential partial match, withhold the tail.
                let safeCount = buffer.count - Self.maxMarkerLength
                if safeCount > 0 {
                    let safeEnd = buffer.index(buffer.startIndex, offsetBy: safeCount)
                    let safe = String(buffer[..<safeEnd])
                    buffer = String(buffer[safeEnd...])
                    if !safe.isEmpty {
                        pieces.append(contentsOf: emitBuffer(safe))
                    }
                }
                // Withhold the rest — can't determine yet.
                break
            }

            // No marker and no partial marker possibility — release the entire buffer
            // except the tail that could be the start of a future marker.
            let holdBack = min(Self.maxMarkerLength - 1, buffer.count)
            let releaseCount = buffer.count - holdBack
            if releaseCount > 0 {
                let releaseEnd = buffer.index(buffer.startIndex, offsetBy: releaseCount)
                let released = String(buffer[..<releaseEnd])
                buffer = String(buffer[releaseEnd...])
                pieces.append(contentsOf: emitBuffer(released))
            }
            break
        }

        return pieces
    }

    /// The markers we're looking for in the current state.
    private func currentMarkers() -> [String] {
        switch state {
        case .content:
            suppressReasoning && !sawMarker ? [Self.openTag, Self.closeTag] : [Self.openTag]
        case .reasoning:
            [Self.closeTag]
        }
    }

    /// The marker whose complete match starts earliest in the buffer, if any.
    private func earliestMatch(
        of markers: [String]
    ) -> (marker: String, range: Range<String.Index>)? {
        markers
            .compactMap { marker in
                buffer.range(of: marker, options: .literal).map { (marker: marker, range: $0) }
            }
            .min { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// Check if the tail of the buffer could be a partial match for the marker.
    private func hasPotentialPartialMarker(_ marker: String) -> Bool {
        // Check if any suffix of buffer is a prefix of the marker.
        let markerLen = marker.count
        let checkLen = min(buffer.count, markerLen - 1)
        guard checkLen > 0 else { return false }

        for length in (1 ... checkLen).reversed() {
            let suffixStart = buffer.index(buffer.endIndex, offsetBy: -length)
            let suffix = buffer[suffixStart...]
            let markerPrefix = marker.prefix(length)
            if suffix == markerPrefix {
                return true
            }
        }
        return false
    }

    /// Classify a string as content or reasoning and wrap it in the appropriate Piece.
    /// When `suppressReasoning` is true, reasoning content is dropped (returns empty).
    private func emitBuffer(_ text: String) -> [Piece] {
        guard !text.isEmpty else { return [] }
        switch state {
        case .content:
            return [.content(text)]
        case .reasoning:
            if suppressReasoning {
                return [] // silently drop
            }
            return [.reasoning(text)]
        }
    }
}
