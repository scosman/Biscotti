import SwiftUI

/// A row showing a spinner/icon and a status label. Used for download/transcription progress.
public struct StatusRow: View {
    private let message: String
    private let isProgress: Bool

    /// Creates a status row.
    /// - Parameters:
    ///   - message: The status text to display.
    ///   - isProgress: When true, shows a spinning progress indicator; otherwise shows a checkmark.
    public init(_ message: String, isProgress: Bool = true) {
        self.message = message
        self.isProgress = isProgress
    }

    public var body: some View {
        HStack(spacing: Tokens.spacingSM) {
            if isProgress {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            Text(message)
                .font(Tokens.metadataFont)
                .foregroundStyle(Tokens.secondaryText)
        }
    }
}

#Preview("Status Row - Progress") {
    StatusRow("Downloading model...")
        .padding()
}

#Preview("Status Row - Complete") {
    StatusRow("Ready", isProgress: false)
        .padding()
}
