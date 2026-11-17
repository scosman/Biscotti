import DesignSystem
import SwiftUI

// MARK: - Shared sheet components

/// Sage capsule badge with a star icon and "Recommended" label.
/// Shared by both the LLM and Speech to Text Model sheets.
struct RecommendedBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "star.fill")
                .font(.caption2)
            Text("Recommended")
                .font(.caption)
        }
        .foregroundStyle(.sage)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(Color.sage.opacity(0.15))
        )
    }
}

/// Sage checkmark circle with "Default" label. Shown when a model
/// is downloaded and selected as the active default.
/// Shared by both the LLM and Speech to Text Model sheets.
struct DefaultIndicator: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.sage)
            Text("Default")
                .font(Tokens.metadataFont)
                .foregroundStyle(Tokens.secondaryText)
        }
    }
}

/// Warning chip with an exclamation icon and configurable text.
/// Shared by both the LLM and Speech to Text Model sheets.
struct WarningChip: View {
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
            Text(text)
                .font(.caption)
        }
        .foregroundStyle(Tokens.warningChipText)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(Tokens.warningChipFill)
        )
    }
}
