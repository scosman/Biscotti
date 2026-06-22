import DataStore
import DesignSystem
import SwiftUI

/// A sheet that lets the user map each diarization speaker to a person.
///
/// Each speaker row shows a color dot + "Speaker N" label and a pill
/// that opens a filterable person-picker popover. Changes apply
/// immediately; the Done button just dismisses.
struct SpeakerMappingSheet: View {
    let data: SpeakerSheetData
    let onAssign: (Int, UUID) async -> Void
    let onAddPerson: (Int, String) async -> Void
    let onUnassign: (Int) async -> Void
    let onDismiss: () -> Void

    /// Tracks which speaker's popover is currently open (nil = none).
    @State private var openPopoverSpeakerID: Int?

    /// Whether the initial scroll-to-focused-speaker has fired.
    /// Only scrolls once on appear; reloads after assignment changes
    /// do not re-scroll.
    @State private var didInitialScroll = false

    /// Focus state for Tab navigation between speaker-row picker pills
    /// and the Done button. Each speaker row's pill is focusable so the
    /// user can Tab through them without the mouse.
    @FocusState private var focusedRow: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spacingMD) {
            VStack(alignment: .leading, spacing: Tokens.spacingXS) {
                Text("Assign Speaker Names")
                    .font(.headline)
                Text("Match each detected speaker to a person.")
                    .font(Tokens.metadataFont)
                    .foregroundStyle(.inkSecondary)
            }

            if data.rows.isEmpty {
                Text("No speakers detected in this transcript.")
                    .font(.system(size: 14))
                    .foregroundStyle(.inkSecondary)
                    .padding(.vertical, Tokens.spacingMD)
            } else {
                speakerRowList
            }

            Divider()

            HStack {
                Spacer()
                Button("Done") { onDismiss() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
        }
        .padding(Tokens.spacingLG)
        .frame(minWidth: 400)
    }

    /// Speaker rows wrapped in a `ScrollViewReader` so the sheet
    /// can scroll to the clicked speaker on initial presentation
    /// (ui_design.md 3.2: "focused on that speaker").
    private var speakerRowList: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: Tokens.spacingSM) {
                ForEach(data.rows) { row in
                    speakerRow(row)
                        .id(row.speakerID)
                }
            }
            .onAppear {
                guard !didInitialScroll,
                      let focused = data.focusedSpeakerID
                else { return }
                didInitialScroll = true
                proxy.scrollTo(focused, anchor: .center)
            }
        }
    }

    // MARK: - Speaker row

    private func speakerRow(_ row: SpeakerRow) -> some View {
        HStack(spacing: Tokens.spacingSM) {
            // Color dot matching the transcript color for this speaker
            // (respects merged-speaker color keys from §13.5)
            Circle()
                .fill(TranscriptContent.speakerColor(
                    forSpeakerID: row.speakerID,
                    colorKeys: data.colorKeys
                ))
                .frame(width: 10, height: 10)

            Text(row.label)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.ink)
                .frame(minWidth: 80, alignment: .leading)

            personPickerPill(for: row)

            Spacer()
        }
    }

    // MARK: - Person picker pill + popover

    private func personPickerPill(for row: SpeakerRow) -> some View {
        Button {
            if openPopoverSpeakerID == row.speakerID {
                openPopoverSpeakerID = nil
            } else {
                openPopoverSpeakerID = row.speakerID
            }
        } label: {
            pillLabel(for: row)
        }
        .buttonStyle(.plain)
        .focused($focusedRow, equals: row.speakerID)
        .popover(
            isPresented: Binding(
                get: { openPopoverSpeakerID == row.speakerID },
                set: { if !$0 { openPopoverSpeakerID = nil } }
            ),
            arrowEdge: .bottom
        ) {
            PersonPickerPopover(
                row: row,
                invitees: data.invitees,
                allPeople: data.people,
                onAssign: { personID in
                    openPopoverSpeakerID = nil
                    Task { await onAssign(row.speakerID, personID) }
                },
                onAddPerson: { name in
                    openPopoverSpeakerID = nil
                    Task { await onAddPerson(row.speakerID, name) }
                },
                onUnassign: {
                    openPopoverSpeakerID = nil
                    Task { await onUnassign(row.speakerID) }
                },
                onDismiss: {
                    openPopoverSpeakerID = nil
                }
            )
        }
    }

    private func pillLabel(for row: SpeakerRow) -> some View {
        HStack(spacing: Tokens.spacingXS) {
            Text(row.assigned?.name ?? "Unassigned")
                .font(.system(size: 13))
                .foregroundStyle(
                    row.assigned != nil ? .ink : .inkTertiary
                )
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9))
                .foregroundStyle(.inkTertiary)
        }
        .padding(.horizontal, Tokens.spacingSM)
        .padding(.vertical, Tokens.spacingXS)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.neutralChip)
        )
    }
}

// MARK: - Person picker popover

/// The filterable popover content for selecting a person assignment.
///
/// Contains: search field (auto-focused), conditional Unassign action
/// (shown only when the speaker has an assignment), Invitees/All People
/// sections (capped at 15 rows), inline Add action, and a `+ N more`
/// status row. Supports keyboard navigation.
private struct PersonPickerPopover: View {
    let row: SpeakerRow
    let invitees: [PersonData]
    let allPeople: [PersonData]
    let onAssign: (UUID) -> Void
    let onAddPerson: (String) -> Void
    let onUnassign: () -> Void
    let onDismiss: () -> Void

    @State private var query = ""
    @FocusState private var isSearchFocused: Bool

    /// The index of the currently highlighted selectable item for
    /// keyboard navigation. `nil` means nothing is highlighted.
    @State private var highlightedIndex: Int?

    /// The computed picker result, updated every keystroke.
    private var pickerResult: PersonPickerResult {
        computePersonPickerResult(
            invitees: invitees,
            allPeople: allPeople,
            query: query
        )
    }

    /// Whether the speaker currently has an assignment (controls
    /// whether the Unassign action is shown).
    private var isAssigned: Bool {
        row.assigned != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchField
            Divider()
            listContent
        }
        .frame(width: 280)
        .onAppear {
            isSearchFocused = true
        }
    }

    // MARK: - Search field

    private var searchField: some View {
        TextField("Filter people\u{2026}", text: $query)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(Tokens.spacingSM)
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

    // MARK: - List content (no internal scrolling — capped at 15 rows)

    private var listContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            unassignRow
            inviteesSection
            allPeopleSection
            addRow
            statusRow
        }
    }

    // MARK: - Unassign

    @ViewBuilder
    private var unassignRow: some View {
        // Show only when the speaker currently has an assignment
        if isAssigned {
            let isHighlighted = highlightedIndex == 0
            Button {
                onUnassign()
            } label: {
                HStack(spacing: Tokens.spacingSM) {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(.inkSecondary)
                    Text("Unassign")
                        .font(.system(size: 13))
                        .foregroundStyle(.ink)
                    Spacer()
                }
                .padding(.horizontal, Tokens.spacingSM)
                .padding(.vertical, 6)
                .background(highlightBackground(isHighlighted))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var inviteesSection: some View {
        if !pickerResult.invitees.isEmpty {
            pickerSectionHeader("INVITEES")
            ForEach(pickerResult.invitees) { person in
                personRow(person)
            }
        }
    }

    @ViewBuilder
    private var allPeopleSection: some View {
        if !pickerResult.allPeople.isEmpty {
            pickerSectionHeader("ALL PEOPLE")
            ForEach(pickerResult.allPeople) { person in
                personRow(person)
            }
        }
    }

    // MARK: - Add row

    @ViewBuilder
    private var addRow: some View {
        if let addText = pickerResult.addOption {
            let items = pickerSelectableItems(
                result: pickerResult, isAssigned: isAssigned
            )
            let itemIndex = items.firstIndex(of: .add)
            let isHighlighted = highlightedIndex == itemIndex
            Button {
                onAddPerson(addText)
            } label: {
                HStack(spacing: Tokens.spacingSM) {
                    Image(systemName: "plus")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.accentColor)
                    Text("Add \"\(addText)\"")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.accentColor)
                    Spacer()
                }
                .padding(.horizontal, Tokens.spacingSM)
                .padding(.vertical, 6)
                .background(highlightBackground(isHighlighted))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Status row

    @ViewBuilder
    private var statusRow: some View {
        if pickerResult.hiddenCount > 0 {
            Text("+ \(pickerResult.hiddenCount) more \u{2014} type to filter")
                .font(Tokens.metadataFont)
                .foregroundStyle(.inkSecondary)
                .padding(.horizontal, Tokens.spacingSM)
                .padding(.vertical, 6)
        }
    }

    // MARK: - Helpers

    private func pickerSectionHeader(
        _ title: String
    ) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.inkTertiary)
            .padding(.horizontal, Tokens.spacingSM)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }

    private func personRow(_ person: PersonData) -> some View {
        let items = pickerSelectableItems(
            result: pickerResult, isAssigned: isAssigned
        )
        let itemIndex = items.firstIndex(of: .person(person.id))
        let isHighlighted = highlightedIndex == itemIndex
        return Button {
            onAssign(person.id)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(person.name)
                    .font(.system(size: 13))
                    .foregroundStyle(.ink)
                if let email = person.email, !email.isEmpty {
                    Text(email)
                        .font(.caption2)
                        .foregroundStyle(.inkSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Tokens.spacingSM)
            .padding(.vertical, 4)
            .background(highlightBackground(isHighlighted))
        }
        .buttonStyle(.plain)
    }

    private func highlightBackground(
        _ isHighlighted: Bool
    ) -> some ShapeStyle {
        isHighlighted
            ? AnyShapeStyle(Color.accentColor.opacity(0.15))
            : AnyShapeStyle(Color.clear)
    }

    // MARK: - Keyboard navigation

    private func moveHighlight(by delta: Int) {
        let items = pickerSelectableItems(
            result: pickerResult, isAssigned: isAssigned
        )
        highlightedIndex = pickerMoveHighlight(
            current: highlightedIndex, delta: delta, items: items
        )
    }

    private func commitHighlighted() {
        let items = pickerSelectableItems(
            result: pickerResult, isAssigned: isAssigned
        )
        let action = pickerCommitAction(
            index: highlightedIndex, items: items,
            result: pickerResult
        )
        switch action {
        case .none:
            break
        case let .assign(personID):
            onAssign(personID)
        case let .addPerson(name):
            onAddPerson(name)
        case .unassign:
            onUnassign()
        }
    }
}

// MARK: - Keyboard navigation (pure helpers)

/// Selectable item kinds for keyboard indexing.
private enum PickerSelectableItem: Equatable {
    case unassign
    case person(UUID)
    case add
}

/// Builds the ordered list of selectable items from a picker result.
/// The Unassign action is only included when the speaker has an
/// assignment (`isAssigned == true`); when unassigned it is hidden.
private func pickerSelectableItems(
    result: PersonPickerResult, isAssigned: Bool
) -> [PickerSelectableItem] {
    var items: [PickerSelectableItem] = []
    if isAssigned {
        items.append(.unassign)
    }
    for person in result.invitees {
        items.append(.person(person.id))
    }
    for person in result.allPeople {
        items.append(.person(person.id))
    }
    if result.addOption != nil {
        items.append(.add)
    }
    return items
}

/// Computes the next highlight index after a key press.
private func pickerMoveHighlight(
    current: Int?, delta: Int,
    items: [PickerSelectableItem]
) -> Int? {
    guard !items.isEmpty else { return nil }

    if let cur = current {
        var next = cur + delta
        if next < 0 { next = items.count - 1 }
        if next >= items.count { next = 0 }
        return next
    } else {
        return delta > 0 ? 0 : items.count - 1
    }
}

/// The action determined by committing the current keyboard highlight.
private enum PickerCommitAction {
    case none
    case assign(UUID)
    case addPerson(String)
    case unassign
}

/// Determines which action to perform when the user presses Return.
private func pickerCommitAction(
    index: Int?, items: [PickerSelectableItem],
    result: PersonPickerResult
) -> PickerCommitAction {
    guard !items.isEmpty else { return .none }

    if let idx = index, idx < items.count {
        switch items[idx] {
        case .unassign:
            return .unassign
        case let .person(personID):
            return .assign(personID)
        case .add:
            if let addText = result.addOption {
                return .addPerson(addText)
            }
            return .none
        }
    } else if let addText = result.addOption {
        // No highlight but Add is available -> perform Add (§14.5)
        return .addPerson(addText)
    }
    return .none
}
