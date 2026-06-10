import SwiftUI

/// A row showing a spinner/icon and a status label, with an optional subtitle
/// for secondary detail (e.g. engine status during transcription).
public struct StatusRow: View {
    private let message: String
    private let subtitle: String?
    private let isProgress: Bool

    /// Creates a status row.
    /// - Parameters:
    ///   - message: The primary status text to display.
    ///   - subtitle: An optional secondary status line shown below the primary text.
    ///   - isProgress: When true, shows a spinning progress indicator; otherwise shows a checkmark.
    public init(_ message: String, subtitle: String? = nil, isProgress: Bool = true) {
        self.message = message
        self.subtitle = subtitle
        self.isProgress = isProgress
    }

    public var body: some View {
        HStack(alignment: .top, spacing: Tokens.spacingSM) {
            if isProgress {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            VStack(alignment: .leading, spacing: Tokens.spacingXS) {
                Text(message)
                    .font(Tokens.metadataFont)
                    .foregroundStyle(Tokens.secondaryText)

                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Tokens.secondaryText.opacity(0.8))
                }
            }
        }
    }
}

#Preview("Status Row - Progress") {
    StatusRow("Downloading model...")
        .padding()
}

#Preview("Status Row - With Subtitle") {
    StatusRow("Transcribing\u{2026}", subtitle: "Downloading speech-to-text model")
        .padding()
}

#Preview("Status Row - Complete") {
    StatusRow("Ready", isProgress: false)
        .padding()
}
