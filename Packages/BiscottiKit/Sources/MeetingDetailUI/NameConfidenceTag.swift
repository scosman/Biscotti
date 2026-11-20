import DataStore
import DesignSystem
import SwiftUI

/// Says where a speaker's name came from and how sure the
/// app is ("✓ Confirmed", "Screen · High", "Voice · Medium", "Guess").
/// Text and outline style carry the meaning, not color: confirmed names
/// get a solid outline, everything else a dashed one, and a guess also
/// gets a question mark.
struct NameConfidenceTag: View {
    let provenance: SpeakerNameProvenance

    var body: some View {
        HStack(spacing: 3) {
            if provenance.source == .guess {
                Image(systemName: "questionmark.circle")
            }
            Text(provenance.badgeText)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(provenance.isTrusted ? Color.ink : Color.inkSecondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .overlay(
            Capsule().strokeBorder(
                Color.inkTertiary,
                style: StrokeStyle(lineWidth: 1, dash: provenance.isTrusted ? [] : [3, 2])
            )
        )
        .help(helpText)
        .accessibilityLabel("Name: \(provenance.badgeText). \(provenance.detail ?? "")")
    }

    private var helpText: String {
        var lines: [String] = []
        if let detail = provenance.detail { lines.append(detail) }
        if !provenance.isTrusted {
            lines.append("Click the name to confirm or change it.")
        }
        return lines.joined(separator: "\n")
    }
}
