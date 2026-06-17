import AppKit
import DesignSystem
import Recording
import SwiftUI

/// The note composer and notes list section of the recording pane.
///
/// Extracted from `RecordingView` to keep each file under the lint
/// body-length limit. Owns the composer text state, inline-edit state,
/// and delegates mutations to the view model.
struct RecordingNotesView: View {
    @Bindable var viewModel: RecordingViewModel

    // Composer state
    @State private var composerText: String = ""
    @FocusState private var composerFocused: Bool

    /// Binding for the pending composer text, read by the parent
    /// when Stop & Save is tapped.
    @Binding var pendingComposerText: String

    /// Inline note edit state, owned by the parent so Stop & Save
    /// can commit any in-progress edit before stopping.
    @Binding var editingNoteID: UUID?
    @Binding var editingNoteText: String

    var body: some View {
        noteComposer

        if !viewModel.notes.isEmpty {
            notesList
        }
    }

    // MARK: - Note composer

    private var noteComposer: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus")
                .foregroundStyle(Color.inkTertiary)
                .font(.system(size: 13))

            TextField("Add a note\u{2026}", text: $composerText)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .focused($composerFocused)
                .onSubmit {
                    submitComposer()
                }

            Button {
                submitComposer()
            } label: {
                Text("Add note")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.sage)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: Tokens.buttonRadius)
                            .fill(Color.softSageFill)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 11)
                .fill(Tokens.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(Color.cardStroke, lineWidth: 0.5)
        )
        .onChange(of: composerText) { _, newValue in
            pendingComposerText = newValue
        }
    }

    private func submitComposer() {
        let trimmed = composerText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        viewModel.addNote(trimmed)
        composerText = ""
        pendingComposerText = ""
        composerFocused = true
    }

    // MARK: - Notes list

    private var notesList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(
                Array(viewModel.notes.enumerated()),
                id: \.element.id
            ) { index, note in
                if index > 0 {
                    Divider()
                }

                noteRow(note)
            }
        }
    }

    private func noteRow(_ note: MeetingNote) -> some View {
        NoteRowView(
            note: note,
            isEditing: editingNoteID == note.id,
            editingText: $editingNoteText,
            onBeginEdit: { beginNoteEdit(note) },
            onCommitEdit: { commitNoteEdit(note) },
            onCancelEdit: { cancelNoteEdit() },
            onDelete: { viewModel.removeNote(id: note.id) }
        )
    }

    // MARK: - Note edit helpers

    private func beginNoteEdit(_ note: MeetingNote) {
        editingNoteID = note.id
        editingNoteText = note.text
    }

    private func commitNoteEdit(_ note: MeetingNote) {
        // Guard: if the edit was already committed (or cancelled) by
        // another path (e.g. commitPendingNoteEdit on Stop fired
        // before the click-away monitor), bail out to avoid reading
        // stale/empty editingNoteText and accidentally deleting the
        // note.
        guard editingNoteID == note.id else { return }
        let trimmed = editingNoteText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            viewModel.removeNote(id: note.id)
        } else {
            viewModel.updateNote(id: note.id, text: trimmed)
        }
        editingNoteID = nil
        editingNoteText = ""
    }

    private func cancelNoteEdit() {
        editingNoteID = nil
        editingNoteText = ""
    }
}

// MARK: - Note row (owns hover + click-away state)

/// A single note row with hover-reveal delete and click-away commit.
///
/// Extracted as a struct so each row owns its own `@State` for
/// hover tracking and the click-away event monitor.
private struct NoteRowView: View {
    let note: MeetingNote
    let isEditing: Bool
    @Binding var editingText: String
    let onBeginEdit: () -> Void
    let onCommitEdit: () -> Void
    let onCancelEdit: () -> Void
    let onDelete: () -> Void

    @State private var rowHovered = false
    @State private var xmarkHovered = false

    /// The editing field's frame for click-away hit testing.
    @State private var editFieldFrame: CGRect = .zero

    /// Local event monitor for click-away commit.
    @State private var clickAwayMonitor: Any?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(
                RecordingViewModel
                    .formatNoteTimestamp(note.timestamp)
            )
            .font(.biscottiMono(11.5))
            .foregroundStyle(Color.sage)
            .frame(width: 46, alignment: .leading)

            if isEditing {
                TextField("", text: $editingText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Color.ink)
                    .onSubmit { onCommitEdit() }
                    .onExitCommand { onCancelEdit() }
                    .background(editFieldFrameCapture)
            } else {
                Text(note.text)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Color.ink)
                    .lineSpacing(3)
                    .frame(
                        maxWidth: .infinity,
                        alignment: .leading
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { onBeginEdit() }
            }

            Spacer(minLength: 0)

            Button { onDelete() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(
                        xmarkHovered
                            ? Color.signalRed
                            : Color.inkTertiary
                    )
            }
            .buttonStyle(.plain)
            .onHover { hovering in xmarkHovered = hovering }
            .opacity(rowHovered ? 1 : 0)
        }
        .padding(.vertical, 13)
        .contentShape(Rectangle())
        .onHover { hovering in rowHovered = hovering }
        .onChange(of: isEditing) { _, editing in
            if editing {
                installClickAwayMonitor()
            } else {
                removeClickAwayMonitor()
            }
        }
        .onDisappear { removeClickAwayMonitor() }
    }

    // MARK: - Click-away helpers

    /// Captures the edit field's frame for click-away hit testing.
    private var editFieldFrameCapture: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear {
                    editFieldFrame = proxy.frame(in: .global)
                }
                .onChange(
                    of: proxy.frame(in: .global)
                ) { _, newFrame in
                    editFieldFrame = newFrame
                }
        }
    }

    /// Installs a local event monitor that commits the edit when the
    /// user clicks outside the editing field (mirrors the approach
    /// used by `EditableMeetingTitle`).
    private func installClickAwayMonitor() {
        removeClickAwayMonitor()
        clickAwayMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown]
        ) { event in
            guard let contentView = event.window?.contentView
            else { return event }
            let loc = event.locationInWindow
            let flipped = CGPoint(
                x: loc.x,
                y: contentView.bounds.height - loc.y
            )
            if !editFieldFrame.contains(flipped) {
                Task { @MainActor in onCommitEdit() }
            }
            return event
        }
    }

    /// Removes the click-away monitor if installed.
    private func removeClickAwayMonitor() {
        if let monitor = clickAwayMonitor {
            NSEvent.removeMonitor(monitor)
            clickAwayMonitor = nil
        }
    }
}
