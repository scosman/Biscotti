import DataStore
import DesignSystem
import SwiftUI

/// A sheet that lets the user map each diarization speaker to a person.
///
/// Each speaker row shows a color dot + "Speaker N" label and a `Menu`
/// picker with sections: Invitees, People, Add person, Unassigned.
/// Changes apply immediately; the Done button just dismisses.
struct SpeakerMappingSheet: View {
    let data: SpeakerSheetData
    let onAssign: (Int, UUID) async -> Void
    let onAddPerson: (Int, String) async -> Void
    let onUnassign: (Int) async -> Void
    let onDismiss: () -> Void

    /// Per-row inline text field state for "Add person..." entries.
    @State private var addPersonText: [Int: String] = [:]

    /// Tracks which row's text field is being shown.
    @State private var showingAddField: Int?

    /// Whether the initial scroll-to-focused-speaker has fired.
    /// Only scrolls once on appear; reloads after assignment changes
    /// do not re-scroll.
    @State private var didInitialScroll = false

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spacingMD) {
            VStack(alignment: .leading, spacing: Tokens.spacingXS) {
                Text("Rename speakers")
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
            Circle()
                .fill(speakerColor(for: row.speakerID))
                .frame(width: 10, height: 10)

            Text(row.label)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.ink)
                .frame(minWidth: 80, alignment: .leading)

            assignmentMenu(for: row)

            Spacer()
        }
    }

    // MARK: - Assignment menu

    private func assignmentMenu(for row: SpeakerRow) -> some View {
        Menu {
            assignmentMenuContent(for: row)
        } label: {
            assignmentMenuLabel(for: row)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .popover(
            isPresented: Binding(
                get: { showingAddField == row.speakerID },
                set: { if !$0 { showingAddField = nil } }
            )
        ) {
            addPersonPopover(speakerID: row.speakerID)
        }
    }

    @ViewBuilder
    private func assignmentMenuContent(
        for row: SpeakerRow
    ) -> some View {
        if !data.invitees.isEmpty {
            Section("Invitees") {
                ForEach(data.invitees) { person in
                    Button {
                        Task {
                            await onAssign(row.speakerID, person.id)
                        }
                    } label: {
                        personLabel(person)
                    }
                }
            }
        }

        if !data.people.isEmpty {
            Section("People") {
                ForEach(data.people) { person in
                    Button {
                        Task {
                            await onAssign(row.speakerID, person.id)
                        }
                    } label: {
                        personLabel(person)
                    }
                }
            }
        }

        Divider()

        Button {
            showingAddField = row.speakerID
            addPersonText[row.speakerID] = ""
        } label: {
            Label("Add person\u{2026}", systemImage: "plus")
        }

        // Spec (ui_design.md 3.3, functional_spec 4.6): Unassigned is
        // always present in the menu; disabled when already unassigned.
        Button {
            Task { await onUnassign(row.speakerID) }
        } label: {
            Label("Unassigned", systemImage: "xmark")
        }
        .disabled(row.assigned == nil)
    }

    private func assignmentMenuLabel(
        for row: SpeakerRow
    ) -> some View {
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

    // MARK: - Add person popover

    private func addPersonPopover(speakerID: Int) -> some View {
        VStack(spacing: Tokens.spacingSM) {
            Text("New person name")
                .font(.system(size: 13, weight: .medium))

            TextField(
                "Name",
                text: Binding(
                    get: { addPersonText[speakerID] ?? "" },
                    set: { addPersonText[speakerID] = $0 }
                )
            )
            .textFieldStyle(.roundedBorder)
            .onSubmit {
                let name = addPersonText[speakerID] ?? ""
                guard !name
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
                else { return }
                showingAddField = nil
                Task { await onAddPerson(speakerID, name) }
            }

            HStack {
                Button("Cancel") {
                    showingAddField = nil
                }
                .buttonStyle(.borderless)
                .controlSize(.small)

                Spacer()

                Button("Add") {
                    let name = addPersonText[speakerID] ?? ""
                    guard !name
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty
                    else { return }
                    showingAddField = nil
                    Task { await onAddPerson(speakerID, name) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(Tokens.spacingMD)
        .frame(width: 220)
    }

    // MARK: - Helpers

    private func personLabel(_ person: PersonData) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(person.name)
            if let email = person.email, !email.isEmpty {
                Text(email)
                    .font(.caption2)
                    .foregroundStyle(.inkSecondary)
            }
        }
    }

    /// Speaker color matching the transcript rendering.
    private func speakerColor(for speakerID: Int) -> Color {
        let colorKey = "speaker-\(speakerID)"
        return Tokens.avatarPalette[
            avatarColorIndex(
                forKey: colorKey,
                paletteCount: Tokens.avatarPalette.count
            )
        ]
    }
}
