import SwiftUI

/// A left-to-right wrapping layout. Places children horizontally until
/// the proposed width is exceeded, then wraps to the next row.
///
/// Pure `Layout`-protocol conformance -- no `GeometryReader`, no
/// `PreferenceKey`. Unit-testable via `sizeThatFits` / `placeSubviews`.
public struct FlowLayout: Layout {
    /// Horizontal spacing between items on the same row.
    public var horizontalSpacing: CGFloat

    /// Vertical spacing between rows.
    public var verticalSpacing: CGFloat

    public init(
        horizontalSpacing: CGFloat = 6,
        verticalSpacing: CGFloat = 6
    ) {
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
    }

    public func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) -> CGSize {
        let rows = computeRows(
            subviews: subviews,
            containerWidth: proposal.width ?? .infinity
        )
        return layoutSize(rows: rows)
    }

    public func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) {
        let rows = computeRows(
            subviews: subviews,
            containerWidth: proposal.width ?? bounds.width
        )

        var originY = bounds.minY
        for row in rows {
            var originX = bounds.minX
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: originX, y: originY),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(item.size)
                )
                originX += item.size.width + horizontalSpacing
            }
            originY += row.height + verticalSpacing
        }
    }

    // MARK: - Internal geometry

    struct RowItem {
        let index: Int
        let size: CGSize
    }

    struct Row {
        var items: [RowItem] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func computeRows(
        subviews: LayoutSubviews,
        containerWidth: CGFloat
    ) -> [Row] {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        return computeRows(sizes: sizes, containerWidth: containerWidth)
    }

    /// Pure row-computation that takes concrete sizes instead of opaque
    /// `LayoutSubviews`. Testable without instantiating real views.
    func computeRows(
        sizes: [CGSize],
        containerWidth: CGFloat
    ) -> [Row] {
        var rows: [Row] = []
        var currentRow = Row()

        for (index, size) in sizes.enumerated() {
            let neededWidth = currentRow.items.isEmpty
                ? size.width
                : currentRow.width + horizontalSpacing + size.width

            if !currentRow.items.isEmpty, neededWidth > containerWidth {
                rows.append(currentRow)
                currentRow = Row()
                // Recompute for the fresh row (item is first, so just its width).
                let freshWidth = size.width
                currentRow.items.append(RowItem(index: index, size: size))
                currentRow.width = freshWidth
            } else {
                currentRow.items.append(RowItem(index: index, size: size))
                currentRow.width = neededWidth
            }
            currentRow.height = max(currentRow.height, size.height)
        }

        if !currentRow.items.isEmpty {
            rows.append(currentRow)
        }

        return rows
    }

    func layoutSize(rows: [Row]) -> CGSize {
        guard !rows.isEmpty else { return .zero }
        let totalWidth = rows.map(\.width).max() ?? 0
        let totalHeight = rows.map(\.height).reduce(0, +)
            + CGFloat(max(0, rows.count - 1)) * verticalSpacing
        return CGSize(width: totalWidth, height: totalHeight)
    }
}

#if DEBUG
    #Preview("FlowLayout") {
        FlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach(0 ..< 8) { index in
                Text("Tag \(index)")
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.neutralChip, in: Capsule())
            }
        }
        .frame(width: 200)
        .padding()
        .background(Color.paper)
    }
#endif
