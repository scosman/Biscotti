import Foundation

/// A frozen copy of a recording's live transcript at one moment.
///
/// Other features (later `meeting_chat`) read the live transcript only through this.
public struct LiveTranscriptSnapshot: Sendable, Equatable {
    public let sessionID: UUID
    public let revision: Int
    /// The end of the newest audio chunk sent to the engine.
    public let captureWatermark: TimeInterval
    public let transcribedThrough: TimeInterval
    public let settledThrough: TimeInterval
    /// Time order across tracks. Rows without text are left out.
    public let rows: [LiveRow]
    public let gaps: [LiveGap]
    /// False when `rows` hold settled text only.
    public let includesTail: Bool

    /// Rows are put in start-time order (rows that start together keep their
    /// order). Without the tail, every row's `tailText` is cleared and rows
    /// left with no text are dropped, so the flag always describes `rows`.
    public init(
        sessionID: UUID,
        revision: Int,
        captureWatermark: TimeInterval,
        transcribedThrough: TimeInterval,
        settledThrough: TimeInterval,
        rows: [LiveRow],
        gaps: [LiveGap],
        includesTail: Bool
    ) {
        self.sessionID = sessionID
        self.revision = revision
        self.captureWatermark = captureWatermark
        self.transcribedThrough = transcribedThrough
        self.settledThrough = settledThrough
        let kept = rows.compactMap { row -> LiveRow? in
            var row = row
            if !includesTail { row.tailText = "" }
            return row.hasText ? row : nil
        }
        self.rows = kept.enumerated()
            .sorted { ($0.element.startTime, $0.offset) < ($1.element.startTime, $1.offset) }
            .map(\.element)
        self.gaps = gaps
        self.includesTail = includesTail
    }
}
