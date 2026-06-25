import SwiftUI
import Testing
@testable import DesignSystem

/// Tests for `FlowLayout` geometry. Exercises the production
/// `computeRows(sizes:containerWidth:)` and `layoutSize(rows:)` functions
/// directly with concrete `[CGSize]` inputs — no mock subview proxies needed.
@Suite("FlowLayout geometry")
struct FlowLayoutTests {
    // MARK: - Helper

    /// Creates a FlowLayout and computes rows from an array of child sizes
    /// using the production row-computation code path.
    private func computeRows(
        childSizes: [CGSize],
        containerWidth: CGFloat,
        hSpacing: CGFloat = 6,
        vSpacing: CGFloat = 6
    ) -> (rows: [FlowLayout.Row], totalSize: CGSize) {
        let layout = FlowLayout(
            horizontalSpacing: hSpacing,
            verticalSpacing: vSpacing
        )

        let rows = layout.computeRows(
            sizes: childSizes,
            containerWidth: containerWidth
        )
        let totalSize = layout.layoutSize(rows: rows)
        return (rows, totalSize)
    }

    // MARK: - Tests

    @Test("Empty children produce zero size")
    func emptyChildren() {
        let (rows, size) = computeRows(
            childSizes: [], containerWidth: 200
        )
        #expect(rows.isEmpty)
        #expect(size == .zero)
    }

    @Test("Single child fits in one row")
    func singleChild() {
        let (rows, size) = computeRows(
            childSizes: [CGSize(width: 50, height: 20)],
            containerWidth: 200
        )
        #expect(rows.count == 1)
        #expect(rows[0].items.count == 1)
        #expect(size.width == 50)
        #expect(size.height == 20)
    }

    @Test("Multiple children fit in one row")
    func allFitOneRow() {
        // 50 + 6 + 50 + 6 + 50 = 162, fits in 200
        let (rows, size) = computeRows(
            childSizes: [
                CGSize(width: 50, height: 20),
                CGSize(width: 50, height: 20),
                CGSize(width: 50, height: 20)
            ],
            containerWidth: 200
        )
        #expect(rows.count == 1)
        #expect(rows[0].items.count == 3)
        #expect(size.width == 162) // 50 + 6 + 50 + 6 + 50
        #expect(size.height == 20)
    }

    @Test("Children wrap to a second row when width exceeded")
    func wrapsToSecondRow() {
        // Row 1: 80 + 6 + 80 = 166 (fits in 200)
        // Row 2: 80 (wraps, since 166 + 6 + 80 = 252 > 200)
        let (rows, size) = computeRows(
            childSizes: [
                CGSize(width: 80, height: 20),
                CGSize(width: 80, height: 20),
                CGSize(width: 80, height: 25)
            ],
            containerWidth: 200
        )
        #expect(rows.count == 2)
        #expect(rows[0].items.count == 2)
        #expect(rows[1].items.count == 1)
        // Total height = 20 (row 1) + 6 (spacing) + 25 (row 2)
        #expect(size.height == 51)
    }

    @Test("Each child on its own row when very narrow")
    func eachOnOwnRow() {
        let (rows, size) = computeRows(
            childSizes: [
                CGSize(width: 50, height: 15),
                CGSize(width: 50, height: 15),
                CGSize(width: 50, height: 15)
            ],
            containerWidth: 60,
            hSpacing: 6,
            vSpacing: 4
        )
        #expect(rows.count == 3)
        // 15 + 4 + 15 + 4 + 15 = 53
        #expect(size.height == 53)
        #expect(size.width == 50)
    }

    @Test("Custom spacing is applied")
    func customSpacing() {
        // With hSpacing=10: 50 + 10 + 50 = 110
        let (rows, size) = computeRows(
            childSizes: [
                CGSize(width: 50, height: 20),
                CGSize(width: 50, height: 20)
            ],
            containerWidth: 200,
            hSpacing: 10
        )
        #expect(rows.count == 1)
        #expect(size.width == 110)
    }

    @Test("Row height is the tallest child in that row")
    func tallestChildSetsRowHeight() {
        let (rows, _) = computeRows(
            childSizes: [
                CGSize(width: 40, height: 10),
                CGSize(width: 40, height: 30),
                CGSize(width: 40, height: 20)
            ],
            containerWidth: 300
        )
        #expect(rows.count == 1)
        #expect(rows[0].height == 30)
    }
}
