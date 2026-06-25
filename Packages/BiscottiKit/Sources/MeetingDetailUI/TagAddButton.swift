import DesignSystem
import SwiftUI

/// Ghost pill that opens the tag picker popover. Three visual states:
///
/// - **Has tags**: dashed neutral border, "+ Add tag" label.
/// - **Empty** (0 tags): dashed sage border, "Add tags" label with tag glyph.
/// - **Picker open**: solid sage border, active sage fill.
struct TagAddButton: View {
    let hasTags: Bool
    let isPickerOpen: Bool

    @State private var hovered = false

    var body: some View {
        HStack(spacing: 4) {
            if hasTags {
                Image(systemName: "plus")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(textColor)
            } else {
                Image(systemName: "tag")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(textColor)
            }

            Text(hasTags ? "Add tag" : "Add tags")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(textColor)
        }
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(fillColor, in: shape)
        .overlay(borderOverlay)
        .onHover { hovered = $0 }
    }

    // MARK: - Styling

    private var textColor: Color {
        if isPickerOpen || !hasTags {
            return .sage
        }
        return .inkSecondary
    }

    private var fillColor: Color {
        if isPickerOpen {
            return .softSageFill
        }
        if hovered {
            return hasTags ? .neutralChip : .softSageFill
        }
        return .clear
    }

    private var borderOverlay: some View {
        Group {
            if isPickerOpen {
                shape.strokeBorder(.sage, lineWidth: 1)
            } else if hasTags {
                shape.strokeBorder(
                    hovered ? Color.ink.opacity(0.4) : Color.ink.opacity(0.26),
                    style: StrokeStyle(lineWidth: 1, dash: [3, 2])
                )
            } else {
                shape.strokeBorder(
                    Color.sage.opacity(0.55),
                    style: StrokeStyle(lineWidth: 1, dash: [3, 2])
                )
            }
        }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 6)
    }
}

#if DEBUG
    #Preview("TagAddButton States") {
        VStack(spacing: 16) {
            Text("Has tags:").font(.caption)
            TagAddButton(hasTags: true, isPickerOpen: false)

            Text("Empty:").font(.caption)
            TagAddButton(hasTags: false, isPickerOpen: false)

            Text("Picker open:").font(.caption)
            TagAddButton(hasTags: true, isPickerOpen: true)
        }
        .padding()
        .background(Color.paper)
    }
#endif
