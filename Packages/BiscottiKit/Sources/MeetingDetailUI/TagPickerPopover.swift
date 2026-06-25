import DataStore
import DesignSystem
import SwiftUI

/// The filterable popover for adding and toggling tags on a meeting.
///
/// Modelled on `PersonPickerPopover` with one key difference:
/// committing a catalogue row **toggles and keeps the popover open**
/// (the person picker closes on select).
struct TagPickerPopover: View {
    let catalogue: [TagData]
    let appliedTagIDs: Set<UUID>
    let onToggle: (TagData) -> Void
    let onCreate: (String) -> Void
    let onDismiss: () -> Void

    @State private var query = ""
    @FocusState private var isSearchFocused: Bool
    @State private var highlightedIndex: Int?

    private var pickerResult: TagPickerResult {
        computeTagPickerResult(
            catalogue: catalogue,
            applied: appliedTagIDs,
            query: query
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchField
            Divider()
            listContent
        }
        .frame(width: 260)
        .onAppear {
            isSearchFocused = true
        }
    }

    // MARK: - Search field

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.inkTertiary)

            TextField("Add or create a tag\u{2026}", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isSearchFocused)
                .onChange(of: query) { _, _ in
                    highlightedIndex = nil
                }
                .onKeyPress(.upArrow) {
                    moveHighlight(by: -1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    moveHighlight(by: 1)
                    return .handled
                }
                .onKeyPress(.return) {
                    commitHighlighted()
                    return .handled
                }
                .onKeyPress(.escape) {
                    onDismiss()
                    return .handled
                }
        }
        .padding(Tokens.spacingSM)
    }

    // MARK: - List content

    private var listContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            tagsKicker
            catalogueRows
            createRow
        }
    }

    // MARK: - Kicker

    private var tagsKicker: some View {
        Text("TAGS")
            .kicker()
            .foregroundStyle(.inkTertiary)
            .padding(.horizontal, Tokens.spacingSM)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }

    // MARK: - Catalogue rows

    private var catalogueRows: some View {
        ForEach(Array(pickerResult.rows.enumerated()), id: \.element.id) { index, row in
            tagRow(row, index: index)
        }
    }

    private func tagRow(_ row: TagPickerRow, index: Int) -> some View {
        let isHighlighted = highlightedIndex == index
        return Button {
            onToggle(row.tag)
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.tagSwatch(slot: row.tag.colorSlot))
                    .frame(width: 7, height: 7)

                Text(row.tag.name)
                    .font(.system(size: 13))
                    .foregroundStyle(.ink)
                    .lineLimit(1)

                Spacer()

                if row.isApplied {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.sage)
                }
            }
            .padding(.horizontal, Tokens.spacingSM)
            .padding(.vertical, 6)
            .background(highlightBackground(isHighlighted))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Create row

    @ViewBuilder
    private var createRow: some View {
        if let createText = pickerResult.createOption {
            let createIndex = pickerResult.rows.count
            let isHighlighted = highlightedIndex == createIndex
            Button {
                onCreate(createText)
                query = ""
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 12))
                        .foregroundStyle(.sage)

                    Text("Create \"\(createText)\"")
                        .font(.system(size: 13))
                        .foregroundStyle(.sage)

                    Spacer()
                }
                .padding(.horizontal, Tokens.spacingSM)
                .padding(.vertical, 6)
                .background(highlightBackground(isHighlighted))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Highlight background

    private func highlightBackground(
        _ isHighlighted: Bool
    ) -> some ShapeStyle {
        isHighlighted
            ? AnyShapeStyle(Color.sage.opacity(0.15))
            : AnyShapeStyle(Color.clear)
    }

    // MARK: - Keyboard navigation

    private var selectableCount: Int {
        pickerResult.rows.count + (pickerResult.createOption != nil ? 1 : 0)
    }

    private func moveHighlight(by delta: Int) {
        guard selectableCount > 0 else { return }

        if let current = highlightedIndex {
            var next = current + delta
            if next < 0 { next = selectableCount - 1 }
            if next >= selectableCount { next = 0 }
            highlightedIndex = next
        } else {
            highlightedIndex = delta > 0 ? 0 : selectableCount - 1
        }
    }

    private func commitHighlighted() {
        guard selectableCount > 0 else { return }

        if let idx = highlightedIndex, idx < selectableCount {
            if idx < pickerResult.rows.count {
                onToggle(pickerResult.rows[idx].tag)
            } else if let createText = pickerResult.createOption {
                onCreate(createText)
                query = ""
            }
        } else if let createText = pickerResult.createOption {
            // No highlight but create is available -> perform create
            onCreate(createText)
            query = ""
        }
    }
}

#if DEBUG
    #Preview("TagPickerPopover") {
        let tags = [
            TagData(id: UUID(), name: "Customer", colorSlot: 0),
            TagData(id: UUID(), name: "Important", colorSlot: 1),
            TagData(id: UUID(), name: "Follow-up", colorSlot: 2)
        ]
        let applied: Set<UUID> = [tags[0].id]
        TagPickerPopover(
            catalogue: tags,
            appliedTagIDs: applied,
            onToggle: { _ in },
            onCreate: { _ in },
            onDismiss: {}
        )
        .padding()
        .background(Color.paper)
    }
#endif
