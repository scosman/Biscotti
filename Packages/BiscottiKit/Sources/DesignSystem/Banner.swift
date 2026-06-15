import SwiftUI

/// A banner for warnings or errors, with an optional action button (e.g. "Fix...", "Retry").
public struct Banner: View {
    /// The visual style of the banner.
    public enum Style: Sendable {
        case warning
        case error
    }

    private let message: String
    private let style: Style
    private let actionLabel: String?
    private let action: (() -> Void)?

    /// Creates a banner.
    /// - Parameters:
    ///   - message: The banner text.
    ///   - style: `.warning` or `.error` (controls background color and icon).
    ///   - actionLabel: Optional label for the trailing action button.
    ///   - action: Optional closure invoked when the action button is tapped.
    public init(
        _ message: String,
        style: Style,
        actionLabel: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.message = message
        self.style = style
        self.actionLabel = actionLabel
        self.action = action
    }

    public var body: some View {
        HStack(spacing: Tokens.spacingSM) {
            Image(systemName: style == .warning ? "exclamationmark.triangle.fill" : "xmark.circle.fill")
                .foregroundStyle(style == .warning ? .yellow : .signalRed)

            Text(message)
                .font(Tokens.metadataFont)
                .foregroundStyle(.inkSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let actionLabel, let action {
                Button(actionLabel, action: action)
                    .buttonStyle(.borderless)
            }
        }
        .padding(Tokens.spacingSM)
        .background(
            style == .warning ? Tokens.warningBackground : Tokens.errorBackground,
            in: RoundedRectangle(cornerRadius: 6)
        )
    }
}

#Preview("Warning Banner") {
    Banner(
        "System audio may be denied",
        style: .warning,
        actionLabel: "Fix..."
    ) {}
        .padding()
        .background(Tokens.contentBackground)
}

#Preview("Error Banner") {
    Banner(
        "Transcription failed -- Worker stopped.",
        style: .error,
        actionLabel: "Retry"
    ) {}
        .padding()
        .background(Tokens.contentBackground)
}

#Preview("Banner without action") {
    Banner("Something went wrong", style: .error)
        .padding()
        .background(Tokens.contentBackground)
}
