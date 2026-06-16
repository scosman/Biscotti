import SwiftUI

/// Standard audio transport card: play/pause + scrubber + elapsed/total +
/// speed menu, rendered inside a rounded card.
/// Disabled state grays out controls with an explanation.
public struct AudioTransport: View {
    public let isPlaying: Bool
    public let currentTime: TimeInterval
    public let duration: TimeInterval
    public let isDisabled: Bool
    public let rate: Float
    public let speedOptions: [Float]
    public let onPlayPause: () -> Void
    public let onSeek: (TimeInterval) -> Void
    public let onRate: (Float) -> Void

    @State private var isHoveringPlayPause = false

    public init(
        isPlaying: Bool,
        currentTime: TimeInterval,
        duration: TimeInterval,
        isDisabled: Bool,
        rate: Float = 1.0,
        speedOptions: [Float] = [0.5, 1.0, 1.25, 1.5, 2.0],
        onPlayPause: @escaping () -> Void,
        onSeek: @escaping (TimeInterval) -> Void,
        onRate: @escaping (Float) -> Void = { _ in }
    ) {
        self.isPlaying = isPlaying
        self.currentTime = currentTime
        self.duration = duration
        self.isDisabled = isDisabled
        self.rate = rate
        self.speedOptions = speedOptions
        self.onPlayPause = onPlayPause
        self.onSeek = onSeek
        self.onRate = onRate
    }

    public var body: some View {
        Group {
            if isDisabled {
                disabledContent
            } else {
                enabledContent
            }
        }
        .padding(.horizontal, Tokens.spacingMD)
        .padding(.vertical, Tokens.spacingSM)
        .background(
            RoundedRectangle(cornerRadius: Tokens.cardRadius)
                .fill(Tokens.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.cardRadius)
                .stroke(Color.cardStroke, lineWidth: 0.5)
        )
    }

    private var enabledContent: some View {
        HStack(spacing: Tokens.spacingSM) {
            playPauseButton

            Text(Self.formatTime(currentTime))
                .font(.monoCaption)
                .monospacedDigit()
                .foregroundStyle(.inkSecondary)

            Slider(
                value: Binding(
                    get: { currentTime },
                    set: { onSeek($0) }
                ),
                in: 0 ... max(duration, 0.01)
            )
            .tint(.sage)

            Text(Self.formatTime(duration))
                .font(.monoCaption)
                .monospacedDigit()
                .foregroundStyle(.inkSecondary)

            speedMenu
        }
    }

    private var playPauseButton: some View {
        Button(action: onPlayPause) {
            Image(
                systemName: isPlaying
                    ? "pause.fill" : "play.fill"
            )
            .font(.system(size: 15))
            .foregroundStyle(.ink)
            .frame(width: 30, height: 30)
            .background(
                Circle()
                    .fill(isHoveringPlayPause ? Tokens.neutralChip : Color.clear)
            )
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHoveringPlayPause = $0 }
    }

    private var speedMenu: some View {
        Menu {
            ForEach(speedOptions, id: \.self) { option in
                Button {
                    onRate(option)
                } label: {
                    HStack {
                        Text(Self.formatRate(option))
                        if option == rate {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            speedLabel(Self.formatRate(rate), disabled: false)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func speedLabel(
        _ text: String, disabled: Bool
    ) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(disabled ? .inkTertiary : .ink)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: Tokens.buttonRadius)
                    .fill(Tokens.neutralChip)
            )
    }

    private var disabledContent: some View {
        HStack(spacing: Tokens.spacingSM) {
            Image(systemName: "play.fill")
                .font(.system(size: 15))
                .foregroundStyle(.inkTertiary)
                .frame(width: 30, height: 30)

            Text("Audio not available")
                .font(Tokens.metadataFont)
                .foregroundStyle(Tokens.secondaryText)

            Spacer()

            Menu {
                // Empty -- disabled state
            } label: {
                speedLabel(Self.formatRate(1.0), disabled: true)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(true)
        }
    }

    /// Formats a time interval as "M:SS" or "H:MM:SS".
    /// Delegates to the shared `TimeFormatting.formatPlaybackTime`.
    public static func formatTime(
        _ interval: TimeInterval
    ) -> String {
        TimeFormatting.formatPlaybackTime(interval)
    }

    /// Formats a rate as "0.5x", "1x", "1.25x", "1.5x", "2x".
    /// Trims trailing ".0" for whole numbers.
    public static func formatRate(_ rate: Float) -> String {
        if rate == Float(Int(rate)) {
            return "\(Int(rate))\u{00D7}"
        }
        // Format with minimal decimal places
        let formatted = String(format: "%g", rate)
        return "\(formatted)\u{00D7}"
    }
}

#Preview("Audio Transport - Playing") {
    AudioTransport(
        isPlaying: true,
        currentTime: 191,
        duration: 1443,
        isDisabled: false,
        rate: 1.0,
        onPlayPause: {},
        onSeek: { _ in },
        onRate: { _ in }
    )
    .padding()
    .frame(width: 500)
    .background(Tokens.contentBackground)
}

#Preview("Audio Transport - 1.5x Speed") {
    AudioTransport(
        isPlaying: true,
        currentTime: 191,
        duration: 1443,
        isDisabled: false,
        rate: 1.5,
        onPlayPause: {},
        onSeek: { _ in },
        onRate: { _ in }
    )
    .padding()
    .frame(width: 500)
    .background(Tokens.contentBackground)
}

#Preview("Audio Transport - Disabled") {
    AudioTransport(
        isPlaying: false,
        currentTime: 0,
        duration: 0,
        isDisabled: true,
        onPlayPause: {},
        onSeek: { _ in }
    )
    .padding()
    .frame(width: 500)
    .background(Tokens.contentBackground)
}
