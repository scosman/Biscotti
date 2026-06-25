import DataStore
import SwiftUI

/// A neutral pill showing a coloured dot and a tag name. Two sizes:
/// `.detail` (interactive, with optional hover-to-remove X) and
/// `.compact` (display-only, used in the meeting list).
public struct TagPill: View {
    public enum Size {
        case detail
        case compact

        var height: CGFloat {
            switch self {
            case .detail: 22
            case .compact: 17
            }
        }

        var horizontalPadding: CGFloat {
            switch self {
            case .detail: 9
            case .compact: 7
            }
        }

        var cornerRadius: CGFloat {
            switch self {
            case .detail: 6
            case .compact: 5
            }
        }

        var dotDiameter: CGFloat {
            switch self {
            case .detail: 7
            case .compact: 6
            }
        }

        var dotTextGap: CGFloat {
            switch self {
            case .detail: 6
            case .compact: 5
            }
        }

        var font: Font {
            switch self {
            case .detail: .system(size: 11.5, weight: .medium)
            case .compact: .system(size: 10.5, weight: .medium)
            }
        }
    }

    private let tag: TagData
    private let size: Size
    private let onRemove: (() -> Void)?

    @State private var hovered = false
    @State private var xHovered = false

    /// Creates a tag pill.
    /// - Parameters:
    ///   - tag: The tag data to display.
    ///   - size: `.detail` or `.compact`.
    ///   - onRemove: If non-nil (`.detail` only), shows a hover-X that
    ///     calls this closure on click.
    public init(
        tag: TagData,
        size: Size,
        onRemove: (() -> Void)? = nil
    ) {
        self.tag = tag
        self.size = size
        self.onRemove = onRemove
    }

    public var body: some View {
        HStack(spacing: size.dotTextGap) {
            Circle()
                .fill(Color.tagSwatch(slot: tag.colorSlot))
                .frame(width: size.dotDiameter, height: size.dotDiameter)

            Text(tag.name)
                .font(size.font)
                .foregroundStyle(.ink)
                .lineLimit(1)

            if size == .detail, onRemove != nil {
                removeButton
            }
        }
        .padding(.horizontal, size.horizontalPadding)
        .frame(height: size.height)
        .background(
            Color.neutralChip,
            in: RoundedRectangle(cornerRadius: size.cornerRadius)
        )
        .onHover { hovered = $0 }
    }

    private var removeButton: some View {
        Button {
            onRemove?()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(xHovered ? .signalRed : .inkTertiary)
        }
        .buttonStyle(.plain)
        .opacity(hovered ? 1 : 0)
        .onHover { xHovered = $0 }
    }
}

#if DEBUG
    #Preview("TagPill Sizes") {
        let sampleTag = TagData(id: UUID(), name: "Customer", colorSlot: 0)
        let sampleTag2 = TagData(id: UUID(), name: "Important", colorSlot: 1)
        VStack(alignment: .leading, spacing: 12) {
            Text("Detail:").font(.caption)
            HStack(spacing: 6) {
                TagPill(tag: sampleTag, size: .detail, onRemove: {})
                TagPill(tag: sampleTag2, size: .detail, onRemove: {})
            }
            Text("Compact:").font(.caption)
            HStack(spacing: 5) {
                TagPill(tag: sampleTag, size: .compact)
                TagPill(tag: sampleTag2, size: .compact)
            }
        }
        .padding()
        .background(Color.paper)
    }
#endif
