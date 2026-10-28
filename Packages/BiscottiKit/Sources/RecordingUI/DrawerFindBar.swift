import AppKit
import DesignSystem
import SwiftUI
import TranscriptUI

/// The drawer header while searching: a field, "2 of 5", previous, next and
/// close. Return moves to the next match, Shift-Return to the previous one.
struct DrawerFindBar: View {
    @Bindable var find: FindState
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        HStack(spacing: Tokens.spacingSM) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.inkSecondary)
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)

            TextField("Find in transcript", text: $find.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isFieldFocused)
                .onSubmit {
                    if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                        find.previous()
                    } else {
                        find.next()
                    }
                }
                .padding(.horizontal, Tokens.spacingSM)
                .frame(height: 26)
                .background {
                    RoundedRectangle(cornerRadius: Tokens.buttonRadius, style: .continuous)
                        .fill(Tokens.elevatedFill)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: Tokens.buttonRadius, style: .continuous)
                        .strokeBorder(Tokens.cardStroke, lineWidth: 1)
                }

            if let count = find.countText {
                Text(count)
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(.inkSecondaryLegible)
                    .lineLimit(1)
                    .fixedSize()
            }

            FindBarButton(systemImage: "chevron.up", label: "Previous match") { find.previous() }
                .disabled(find.matches.isEmpty)
            FindBarButton(systemImage: "chevron.down", label: "Next match") { find.next() }
                .disabled(find.matches.isEmpty)
            FindBarButton(systemImage: "xmark", label: "Close find") { find.close() }
        }
        .padding(.horizontal, LiveTranscriptDrawer.sidePadding)
        .onAppear { isFieldFocused = true }
    }
}

private struct FindBarButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(FindBarButtonStyle())
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct FindBarButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? Color.inkSecondary : Color.inkTertiary)
            .background {
                RoundedRectangle(cornerRadius: Tokens.buttonRadius, style: .continuous)
                    .fill(configuration.isPressed ? Tokens.neutralChip : Color.clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Tokens.buttonRadius, style: .continuous)
                    .strokeBorder(Tokens.cardStroke, lineWidth: 1)
            }
    }
}
