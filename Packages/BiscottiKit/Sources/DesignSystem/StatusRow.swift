import SwiftUI

/// A row showing a spinner/icon and a status label, with an optional subtitle
/// for secondary detail (e.g. engine status during transcription).
public struct StatusRow: View {
    public enum Style: Sendable {
        /// Metadata font with a small spinner.
        case standard
        /// A tracked uppercase mono caption with a mini spinner, as above a
        /// transcript draft ("DRAFT · FINAL TRANSCRIPT IN PROGRESS").
        case caption
    }

    private let message: String
    private let subtitle: String?
    private let isProgress: Bool
    private let style: Style

    /// Creates a status row.
    /// - Parameters:
    ///   - message: The primary status text to display.
    ///   - subtitle: An optional secondary status line shown below the primary text.
    ///   - isProgress: When true, shows a spinning progress indicator; otherwise shows a checkmark.
    ///   - style: The text style; `.standard` by default.
    public init(_ message: String, subtitle: String? = nil, isProgress: Bool = true, style: Style = .standard) {
        self.message = message
        self.subtitle = subtitle
        self.isProgress = isProgress
        self.style = style
    }

    public var body: some View {
        HStack(alignment: style == .caption ? .center : .top, spacing: Tokens.spacingSM) {
            if isProgress {
                ProgressView()
                    .controlSize(style == .caption ? .mini : .small)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(style == .caption ? .system(size: 10) : nil)
                    .foregroundStyle(.sage)
            }
            VStack(alignment: .leading, spacing: Tokens.spacingXS) {
                messageText

                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Tokens.secondaryText.opacity(0.8))
                }
            }
        }
    }

    @ViewBuilder
    private var messageText: some View {
        switch style {
        case .standard:
            Text(message)
                .font(Tokens.metadataFont)
                .foregroundStyle(Tokens.secondaryText)
        case .caption:
            Text(message.uppercased())
                .font(.monoCaption)
                .tracking(1.2)
                .foregroundStyle(.inkSecondary)
                .accessibilityLabel(message)
        }
    }
}

#Preview("Status Row - Progress") {
    StatusRow("Downloading model...")
        .padding()
        .background(Tokens.contentBackground)
}

#Preview("Status Row - With Subtitle") {
    StatusRow("Transcribing\u{2026}", subtitle: "Downloading speech-to-text model")
        .padding()
        .background(Tokens.contentBackground)
}

#Preview("Status Row - Complete") {
    StatusRow("Ready", isProgress: false)
        .padding()
        .background(Tokens.contentBackground)
}
