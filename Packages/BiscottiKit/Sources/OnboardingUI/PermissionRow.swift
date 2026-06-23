import DesignSystem
import Permissions
import SwiftUI

/// A single row in the Grant Access permission card. Shows an icon
/// tile, name, description, and a trailing state-dependent control.
///
/// Generic over `Trailing` (the state-dependent right-side view) and
/// `Denial` (optional denial guidance shown below the name/why text).
struct PermissionRow<Trailing: View, Denial: View>: View {
    let icon: String
    let name: String
    let why: String
    let trailingContent: Trailing
    let denialContent: Denial

    init(
        icon: String,
        name: String,
        why: String,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder denial: () -> Denial
    ) {
        self.icon = icon
        self.name = name
        self.why = why
        trailingContent = trailing()
        denialContent = denial()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                // Icon tile
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color.accentWashSoft)
                    .frame(width: 34, height: 34)
                    .overlay(
                        Image(systemName: icon)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.sage)
                    )

                // Name + why
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(.ink)

                    Text(why)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.inkSecondary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)

                // Trailing state view
                trailingContent
            }

            // Denial guidance indented past the icon tile
            denialContent
                .padding(.leading, 48)
                .padding(.top, 6)
        }
        .padding(.vertical, 15)
        .padding(.horizontal, 16)
    }
}

// MARK: - Convenience init (no denial content)

extension PermissionRow where Denial == EmptyView {
    init(
        icon: String,
        name: String,
        why: String,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.init(
            icon: icon,
            name: name,
            why: why,
            trailing: trailing,
            denial: { EmptyView() }
        )
    }
}

// MARK: - Grant pill button

/// A small sage pill button used for the "Grant" action in permission rows.
/// Generalized to accept a custom title and optional leading SF Symbol;
/// defaults preserve the existing call-site signature.
struct GrantPill: View {
    var title: String = "Grant"
    var systemImage: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .medium))
                }
                Text(title)
            }
        }
        .buttonStyle(JoinRecordButtonStyle())
    }
}

// MARK: - Denial guidance

/// Inline denial guidance for mic/calendar: warning icon + "Denied?" + link.
struct DenialGuidanceView: View {
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.warningOchre)
                .font(.system(size: 12))
            Text("Denied?")
                .font(.system(size: 12.5))
                .foregroundStyle(.inkSecondary)
            Button("Open System Settings", action: onOpenSettings)
                .font(.system(size: 12.5))
                .buttonStyle(.plain)
                .foregroundStyle(.sage)
        }
    }
}
