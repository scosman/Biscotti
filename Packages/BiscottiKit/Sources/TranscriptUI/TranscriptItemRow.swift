import AppKit
import DesignSystem
import Formatting
import SwiftUI

/// One row of the bubble list.
///
/// `Equatable` on what it draws (the item, its find highlights and
/// `canSeek`), never on the closures, so the list wraps each row in
/// `.equatable()` and an update re-renders only the rows that changed, for
/// example the one bubble whose tail grew.
struct TranscriptItemRow: View, Equatable {
    let item: TranscriptItem
    let highlights: BubbleHighlights
    let canSeek: Bool
    let onSeek: (TimeInterval) -> Void
    let onSpeaker: (Int) -> Void
    let onSpeakerDebug: ((Int) -> Void)?

    nonisolated static func == (lhs: TranscriptItemRow, rhs: TranscriptItemRow) -> Bool {
        lhs.item == rhs.item && lhs.highlights == rhs.highlights && lhs.canSeek == rhs.canSeek
    }

    var body: some View {
        switch item.kind {
        case let .bubble(bubble):
            BubbleRow(
                bubble: bubble,
                highlights: highlights,
                canSeek: canSeek,
                onSeek: onSeek,
                onSpeaker: onSpeaker,
                onSpeakerDebug: onSpeakerDebug
            )
        case let .gap(_, duration, cause):
            CenteredCaption(text: Self.gapText(duration, cause: cause), help: Self.gapHelp(cause))
        case let .startMarker(time):
            CenteredCaption(text: "Live transcript started at \(TimeFormatting.formatPlaybackTime(time))")
        }
    }

    /// "Not transcribed live · 0:12", or "Audio paused while switching
    /// devices · 0:07".
    static func gapText(_ duration: TimeInterval, cause: GapCause) -> String {
        let caption = switch cause {
        case .notTranscribedLive: "Not transcribed live"
        case .deviceSwitch: "Audio paused while switching devices"
        }
        return "\(caption) \u{00B7} \(formatGap(duration))"
    }

    /// The gap marker's tooltip: whether the saved transcript has the stretch.
    static func gapHelp(_ cause: GapCause) -> String {
        switch cause {
        case .notTranscribedLive: "Recording continued. The saved transcript includes this part."
        case .deviceSwitch: "Your microphone or speakers were switching; nothing was recorded here."
        }
    }

    /// Rounded up, so a gap shorter than a second still reads "0:01".
    static func formatGap(_ duration: TimeInterval) -> String {
        TimeFormatting.formatPlaybackTime(duration.rounded(.up))
    }
}

// MARK: - Bubble row

private struct BubbleRow: View {
    let bubble: Bubble
    let highlights: BubbleHighlights
    let canSeek: Bool
    let onSeek: (TimeInterval) -> Void
    let onSpeaker: (Int) -> Void
    let onSpeakerDebug: ((Int) -> Void)?

    @State private var isHovered = false
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    private var alignment: HorizontalAlignment {
        bubble.side == .leading ? .leading : .trailing
    }

    private var showsPlay: Bool {
        canSeek && isHovered
    }

    var body: some View {
        VStack(alignment: alignment, spacing: Tokens.spacingXS) {
            if let label = bubble.label {
                RunLabelView(
                    label: label,
                    side: bubble.side,
                    speakerID: bubble.speakerID,
                    canSeek: canSeek,
                    showsPlay: showsPlay,
                    playTime: bubble.startTime,
                    onSeek: onSeek,
                    onSpeaker: onSpeaker,
                    onSpeakerDebug: onSpeakerDebug
                )
            }
            BubbleWidthLayout(side: bubble.side) {
                bubbleBody
                    .overlay(alignment: bubble.side == .leading ? .trailing : .leading) {
                        // Bubbles below a run's label play from beside themselves.
                        if bubble.label == nil, showsPlay {
                            PlayButton { onSeek(bubble.startTime) }
                                .offset(x: bubble.side == .leading ? 26 : -26)
                        }
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    private var bubbleBody: some View {
        HStack(alignment: .lastTextBaseline, spacing: Tokens.spacingXS) {
            Text(Self.attributedText(for: bubble, highlights: highlights, underlineTail: differentiateWithoutColor))
                .font(.system(size: 14))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityLabel(accessibilityText)
                .accessibilityActions {
                    if canSeek {
                        Button("Play from here") { onSeek(bubble.startTime) }
                    }
                }
            if bubble.showsTypingDots {
                TypingDots()
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, Tokens.spacingSM)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: Tokens.bubbleRadius, style: .continuous)
                .fill(bubble.side == .trailing ? Tokens.softSageFill : Tokens.neutralChip)
        )
        .contextMenu {
            Button("Copy") {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(bubble.fullText, forType: .string)
            }
        }
    }

    /// "Priya, 0:31: …" for a labeled bubble, "You: …" otherwise; mixed
    /// rows read only their text. Settled text only: tail changes are never read.
    private var accessibilityText: String {
        guard let name = bubble.spokenName else { return bubble.settledText }
        if let label = bubble.label {
            return "\(name), \(TimeFormatting.formatPlaybackTime(label.time)): \(bubble.settledText)"
        }
        return "\(name): \(bubble.settledText)"
    }

    /// Settled text in `ink`, the tail in `inkSecondaryLegible` (dotted
    /// underline with Differentiate Without Color), find matches as backgrounds.
    ///
    /// ui_design.md names `inkSecondary` for the tail and also requires
    /// 4.5:1 on both bubble fills; light `inkSecondary` reaches only 3.6:1, so
    /// the tail uses `inkSecondaryLegible`, which meets the ratio.
    static func attributedText(
        for bubble: Bubble,
        highlights: BubbleHighlights,
        underlineTail: Bool
    ) -> AttributedString {
        let text = bubble.fullText
        var result = AttributedString(text)
        result.foregroundColor = Color.ink
        if !bubble.tailText.isEmpty {
            let tailStart = text.index(text.endIndex, offsetBy: -bubble.tailText.count)
            if let tail = Range(tailStart ..< text.endIndex, in: result) {
                result[tail].foregroundColor = Color.inkSecondaryLegible
                if underlineTail {
                    result[tail].underlineStyle = Text.LineStyle(pattern: .dot)
                }
            }
        }
        for (index, range) in highlights.ranges.enumerated() {
            guard range.upperBound <= text.endIndex, let match = Range(range, in: result) else { continue }
            result[match].backgroundColor = index == highlights.currentIndex
                ? Color.findHighlightFocused
                : Tokens.accentWashStrong
        }
        return result
    }
}

/// Lays out one bubble at most 75% of the row's width, on its side.
private struct BubbleWidthLayout: Layout {
    static let widthFraction: CGFloat = 0.75

    var side: Bubble.Side

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        let height = subviews.map {
            $0.sizeThatFits(ProposedViewSize(width: width * Self.widthFraction, height: nil)).height
        }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: bounds.width * Self.widthFraction, height: nil))
            let originX = side == .leading ? bounds.minX : bounds.maxX - size.width
            subview.place(at: CGPoint(x: originX, y: bounds.minY), proposal: ProposedViewSize(size))
        }
    }
}

// MARK: - Run label

private struct RunLabelView: View {
    let label: RunLabel
    let side: Bubble.Side
    let speakerID: Int?
    let canSeek: Bool
    let showsPlay: Bool
    let playTime: TimeInterval
    let onSeek: (TimeInterval) -> Void
    let onSpeaker: (Int) -> Void
    let onSpeakerDebug: ((Int) -> Void)?

    var body: some View {
        HStack(spacing: Tokens.spacingXS) {
            // The play button keeps its slot while hidden, on the outer side
            // of the label, so nothing moves on hover and a right-aligned
            // "You" label stays flush with its bubble.
            if side == .trailing { playSlot }
            name
            Text("\u{00B7}")
                .font(.system(size: 12))
                .foregroundStyle(.inkTertiary)
                .accessibilityHidden(true)
            time
            if side == .leading { playSlot }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var playSlot: some View {
        if canSeek {
            PlayButton { onSeek(playTime) }
                .opacity(showsPlay ? 1 : 0)
                .allowsHitTesting(showsPlay)
                .accessibilityHidden(true)
        }
    }

    private var nameText: some View {
        Text(label.name)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(TranscriptContent.color(forKey: label.colorKey))
    }

    @ViewBuilder
    private var name: some View {
        if let speakerID {
            Button {
                onSpeaker(speakerID)
            } label: {
                nameText
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help("Change speaker")
            .speakerDebugMenu(onSpeakerDebug.map { action in { action(speakerID) } })
        } else {
            nameText
        }
    }

    @ViewBuilder
    private var time: some View {
        let timeText = Text(TimeFormatting.formatPlaybackTime(label.time))
            .font(Font.biscottiMono(12))
            .foregroundStyle(.inkTertiary)
        if canSeek {
            Button {
                onSeek(label.time)
            } label: {
                timeText
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help("Play from here")
        } else {
            timeText
        }
    }
}

private struct PlayButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "play.fill")
                .font(.system(size: 9))
                .foregroundStyle(.inkTertiary)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help("Play from here")
        .accessibilityLabel("Play from here")
    }
}

// MARK: - Markers and dots

/// A centered caption between hairlines: gap and start markers.
private struct CenteredCaption: View {
    let text: String
    var help: String?

    var body: some View {
        HStack(spacing: Tokens.spacingSM) {
            Rectangle().fill(Tokens.hairline).frame(height: 1)
            caption
            Rectangle().fill(Tokens.hairline).frame(height: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .accessibilityHint(help ?? "")
    }

    @ViewBuilder
    private var caption: some View {
        let caption = Text(text.uppercased())
            .font(.monoCaption)
            .tracking(1.2)
            .foregroundStyle(.inkSecondaryLegible)
            .fixedSize()
        if let help {
            caption.help(help)
        } else {
            caption
        }
    }
}

/// Three 4 pt dots pulsing in turn over 0.9 s; still with Reduce Motion.
struct TypingDots: View {
    static let cycle: TimeInterval = 0.9

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            dots(at: nil)
        } else {
            TimelineView(.periodic(from: .now, by: 0.1)) { context in
                dots(at: context.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    private func dots(at time: TimeInterval?) -> some View {
        HStack(spacing: 3) {
            ForEach(0 ..< 3, id: \.self) { index in
                Circle()
                    .fill(Color.inkTertiary)
                    .frame(width: 4, height: 4)
                    .opacity(time.map { Self.opacity(dot: index, at: $0) } ?? 0.7)
            }
        }
    }

    /// Each dot peaks a third of a cycle after the one before it.
    static func opacity(dot: Int, at time: TimeInterval) -> Double {
        let phase = (time / cycle).truncatingRemainder(dividingBy: 1) - Double(dot) / 3
        return 0.35 + 0.65 * max(0, cos(2 * .pi * phase))
    }
}

// MARK: - Modifiers

private extension View {
    /// Today's DEBUG "Voiceprint Debug…" menu on a speaker name, when wanted.
    @ViewBuilder
    func speakerDebugMenu(_ action: (() -> Void)?) -> some View {
        if let action {
            contextMenu { Button("Voiceprint Debug\u{2026}", action: action) }
        } else {
            self
        }
    }
}
