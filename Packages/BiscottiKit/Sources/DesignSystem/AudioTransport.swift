import SwiftUI

/// Standard audio transport: play/pause + scrubber slider + elapsed/total time.
/// Disabled state grays out controls with an explanation.
public struct AudioTransport: View {
    public let isPlaying: Bool
    public let currentTime: TimeInterval
    public let duration: TimeInterval
    public let isDisabled: Bool
    public let onPlayPause: () -> Void
    public let onSeek: (TimeInterval) -> Void

    public init(
        isPlaying: Bool,
        currentTime: TimeInterval,
        duration: TimeInterval,
        isDisabled: Bool,
        onPlayPause: @escaping () -> Void,
        onSeek: @escaping (TimeInterval) -> Void
    ) {
        self.isPlaying = isPlaying
        self.currentTime = currentTime
        self.duration = duration
        self.isDisabled = isDisabled
        self.onPlayPause = onPlayPause
        self.onSeek = onSeek
    }

    public var body: some View {
        VStack(spacing: Tokens.spacingXS) {
            if isDisabled {
                disabledContent
            } else {
                enabledContent
            }
        }
    }

    private var enabledContent: some View {
        HStack(spacing: Tokens.spacingSM) {
            Button(action: onPlayPause) {
                Image(
                    systemName: isPlaying
                        ? "pause.fill" : "play.fill"
                )
                .font(.title3)
            }
            .buttonStyle(.borderless)

            Slider(
                value: Binding(
                    get: { currentTime },
                    set: { onSeek($0) }
                ),
                in: 0 ... max(duration, 0.01)
            )

            Text(Self.formatTime(currentTime))
                .font(.monoCaption)
                .foregroundStyle(Tokens.secondaryText)

            Text("/")
                .font(.monoCaption)
                .foregroundStyle(Tokens.secondaryText)

            Text(Self.formatTime(duration))
                .font(.monoCaption)
                .foregroundStyle(Tokens.secondaryText)
        }
    }

    private var disabledContent: some View {
        HStack(spacing: Tokens.spacingSM) {
            Image(systemName: "play.fill")
                .font(.title3)
                .foregroundStyle(.inkTertiary)

            Text("Audio not available")
                .font(Tokens.metadataFont)
                .foregroundStyle(Tokens.secondaryText)

            Spacer()
        }
    }

    /// Formats a time interval as "MM:SS" or "H:MM:SS".
    public static func formatTime(
        _ interval: TimeInterval
    ) -> String {
        let total = max(0, Int(interval))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60

        if hours > 0 {
            return String(
                format: "%d:%02d:%02d",
                hours, minutes, seconds
            )
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

#Preview("Audio Transport - Playing") {
    AudioTransport(
        isPlaying: true,
        currentTime: 191,
        duration: 1443,
        isDisabled: false,
        onPlayPause: {},
        onSeek: { _ in }
    )
    .padding()
    .frame(width: 400)
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
    .frame(width: 400)
    .background(Tokens.contentBackground)
}
