import Accessibility
import DesignSystem
import SwiftUI

/// Full-window overlay shown while a qualifying drag hovers.
/// Renders `DropTargetModel.state`: nil = hidden.
/// Applied with `.allowsHitTesting(false)` — the AppKit drop view handles drags.
public struct DropOverlayView: View {
    let model: DropTargetModel

    public init(model: DropTargetModel) {
        self.model = model
    }

    public var body: some View {
        ZStack {
            if let state = model.state {
                overlayContent(state)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.14), value: model.state != nil)
        .onChange(of: model.state != nil) { _, isVisible in
            if isVisible, let state = model.state {
                AccessibilityNotification.Announcement(state.title)
                    .post()
            }
        }
    }

    // MARK: - Full overlay

    @ViewBuilder
    private func overlayContent(_ state: DropOverlayState) -> some View {
        let isSupported = !state.isNeutral

        ZStack {
            // Veil
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Color.dropVeil)

            // Drop zone
            RoundedRectangle(cornerRadius: 9)
                .fill(
                    isSupported
                        ? Color.sage.opacity(0.05) : Color.clear
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(
                            isSupported
                                ? Color.sage.opacity(0.70) : Color.inkTertiary,
                            style: StrokeStyle(
                                lineWidth: 2,
                                dash: [6, 5]
                            )
                        )
                )
                .padding(12)

            // Content
            contentStack(state, isSupported: isSupported)
        }
    }

    // MARK: - Content stack

    private func contentStack(
        _ state: DropOverlayState,
        isSupported: Bool
    ) -> some View {
        VStack(spacing: 14) {
            tile(isSupported: isSupported)
                .padding(.bottom, 6)

            Text(state.title)
                .font(.biscottiSerif(34))
                .tracking(-0.34)
                .foregroundStyle(Color.ink)

            Text(state.subtitle)
                .font(.system(size: 15))
                .foregroundStyle(Color.inkSecondary)
                .lineSpacing(5)
                .frame(maxWidth: 440)

            if state.showsFormatLine {
                Text(Self.formatLine)
                    .font(.biscottiMono(11.5))
                    .tracking(0.7)
                    .foregroundStyle(Color.inkTertiary)
                    .padding(.top, 6)
            }

            if let notice = state.skipNotice {
                skipNoticePill(notice)
            }
        }
        .multilineTextAlignment(.center)
    }

    // MARK: - Tile

    private func tile(isSupported: Bool) -> some View {
        ZStack {
            if isSupported {
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color.accentFill)
                    .overlay(alignment: .top) {
                        // Top inner highlight (the JoinRecordButtonStyle treatment).
                        RoundedRectangle(cornerRadius: 20)
                            .strokeBorder(
                                Color.white.opacity(0.22),
                                lineWidth: 1
                            )
                            .mask(alignment: .top) {
                                Rectangle().frame(height: 21)
                            }
                    }
                    .shadow(
                        color: Color.black.opacity(0.14),
                        radius: 12,
                        y: 10
                    )
            } else {
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color.neutralChip)
            }

            Image(systemName: "waveform")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(
                    isSupported ? Color.white : Color.inkTertiary
                )
        }
        .frame(width: 76, height: 76)
    }

    // MARK: - Skip notice pill

    private func skipNoticePill(
        _ notice: (count: Int, suffix: String)
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 14))
                .foregroundStyle(Color.inkTertiary)

            Group {
                Text("\(notice.count)")
                    .fontWeight(.semibold) +
                    Text(notice.suffix)
            }
            .font(.system(size: 13))
            .foregroundStyle(Color.inkSecondary)
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(
            Color.neutralChip,
            in: RoundedRectangle(cornerRadius: Tokens.buttonRadius)
        )
    }

    // MARK: - Constants

    static let formatLine =
        "WAV \u{00B7} MP3 \u{00B7} M4A \u{00B7} AAC \u{00B7} AIFF \u{00B7} CAF \u{00B7} FLAC \u{00B7} MP4 \u{00B7} MOV"
}
