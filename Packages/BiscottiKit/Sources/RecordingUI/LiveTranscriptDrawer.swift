import DesignSystem
import LiveTranscriptionService
import SwiftUI
import TranscriptUI

/// The live transcript's card: a header with search, the `TRANSCRIPT` kicker
/// and Copy (or the find bar), the bubbles, and a footer with the status and
/// the language menu. The toggle sits over the footer's leading slot.
struct LiveTranscriptDrawer: View {
    static let barHeight: CGFloat = 44
    static let sidePadding: CGFloat = Tokens.spacingMD
    /// How far the toggle sits inside the card's leading edge.
    static let outset: CGFloat = 12
    /// How long Starting lasts before the drawer explains a slow start: the
    /// model is compiling (a load from the compiled cache takes under a second).
    static let slowStartDelay: Duration = .seconds(10)

    /// Whether Starting has lasted long enough to explain why.
    static func isSlowStart(since startingSince: Date?, now: Date) -> Bool {
        guard let startingSince else { return false }
        return .seconds(now.timeIntervalSince(startingSince)) >= slowStartDelay
    }

    let viewModel: RecordingViewModel
    @State private var find = FindState()
    /// Focus returns to the bubbles when find closes, so the next Esc
    /// reaches the drawer and hides it.
    @FocusState private var isListFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if find.isOpen {
                    DrawerFindBar(find: find)
                } else {
                    DrawerHeader(viewModel: viewModel, find: find)
                }
            }
            .frame(height: Self.barHeight)
            Tokens.hairline.frame(height: 0.5)
            DrawerTranscriptBody(viewModel: viewModel, find: find)
                .focused($isListFocused)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Tokens.hairline.frame(height: 0.5)
            DrawerFooter(viewModel: viewModel)
                .frame(height: Self.barHeight)
        }
        .background(Tokens.cardFill)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.drawerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Tokens.drawerRadius, style: .continuous)
                .strokeBorder(Tokens.cardStroke, lineWidth: 0.5)
        }
        .shadow(color: Tokens.cardShadow, radius: 16, y: 6)
        .shadow(color: Tokens.cardShadow, radius: 2, y: 1)
        // The first Esc closes the find bar, the second hides the drawer.
        .onExitCommand {
            if find.isOpen {
                find.close()
            } else {
                viewModel.collapseDrawer()
            }
        }
        .onChange(of: find.isOpen) { _, isOpen in
            if !isOpen { isListFocused = true }
        }
    }
}

// MARK: - Header

private struct DrawerHeader: View {
    let viewModel: RecordingViewModel
    let find: FindState
    @State private var didCopy = false
    @State private var copyResetTask: Task<Void, Never>?

    var body: some View {
        let canCopy = viewModel.canCopyLiveTranscript
        HStack(spacing: Tokens.spacingSM) {
            Button {
                find.isOpen = true
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.inkSecondary)
            .disabled(!canCopy)
            .help("Find in transcript")
            .accessibilityLabel("Find in transcript")

            Text("Transcript")
                .kicker()
                .foregroundStyle(.inkSecondary)
                .accessibilityAddTraits(.isHeader)

            if viewModel.isLiveCatchingUp {
                HStack(spacing: Tokens.spacingXS) {
                    ProgressView().controlSize(.mini)
                    Text(RecordingViewModel.catchingUpText)
                        .font(.monoMeta)
                        .foregroundStyle(.inkSecondaryLegible)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Catching up")
            }

            Spacer(minLength: Tokens.spacingSM)

            Button {
                viewModel.copyLiveTranscript()
                didCopy = true
                copyResetTask?.cancel()
                copyResetTask = Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    guard !Task.isCancelled else { return }
                    didCopy = false
                }
            } label: {
                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
                    .transaction { $0.animation = nil }
            }
            .buttonStyle(.plain)
            .foregroundStyle(didCopy ? .sage : .inkSecondary)
            .disabled(!canCopy)
            .help("Copy transcript")
            .accessibilityLabel(didCopy ? "Copied" : "Copy transcript")

            // Chosen by the user in hardware review (25 October 2026): a
            // collapse control at the header's trailing edge, as in Granola.
            Button {
                viewModel.collapseDrawer()
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.inkSecondary)
            .help("Hide transcript (⌘T)")
            .accessibilityLabel("Hide transcript")
        }
        .padding(.horizontal, LiveTranscriptDrawer.sidePadding)
    }
}

// MARK: - Body

/// The bubbles, or a calm placeholder before there are any.
private struct DrawerTranscriptBody: View {
    @Bindable var viewModel: RecordingViewModel
    let find: FindState

    var body: some View {
        let items = viewModel.liveItems
        Group {
            if items.isEmpty {
                DrawerPlaceholder(viewModel: viewModel)
                    // Nothing to scroll to yet: a note's reveal only opens the drawer.
                    .task(id: viewModel.revealTime) { viewModel.revealTime = nil }
            } else {
                TranscriptBubbleList(
                    items: items,
                    canSeek: false,
                    follow: .live,
                    find: find,
                    revealTime: $viewModel.revealTime,
                    rowPadding: LiveTranscriptDrawer.sidePadding,
                    // The drawer is already at most 880 pt wide; bubbles use all of it.
                    maxRowWidth: .infinity,
                    bottomPadding: 12
                )
            }
        }
        // The list updates in this same transaction; the next main-queue
        // turn comes after the frame is committed, so that is when the rows
        // count as drawn.
        .onChange(of: viewModel.liveRowsRevision) {
            DispatchQueue.main.async { viewModel.liveRowsDrawn() }
        }
    }
}

private struct DrawerPlaceholder: View {
    let viewModel: RecordingViewModel
    @State private var isSlowStart = false

    var body: some View {
        let status = viewModel.liveStatus
        let startingSince = viewModel.liveStartingSince
        let showsSlowStart = isSlowStart || LiveTranscriptDrawer.isSlowStart(since: startingSince, now: Date())
        VStack(spacing: Tokens.spacingSM + Tokens.spacingXS) {
            switch status {
            case .unavailable(.modelMissing):
                LiveModelDownloadPanel(viewModel: viewModel)
            case let .unavailable(reason):
                message(RecordingViewModel.unavailableText(for: reason) + ".")
                message("Recording continues, and the full transcript is made after you stop.")
            case .starting where showsSlowStart:
                ForEach(RecordingViewModel.slowStartMessages(lowOnDisk: viewModel.liveSlowStartIsLowOnDisk), id: \.self) { text in
                    message(text)
                }
            default:
                message("The transcript appears here as people speak.")
            }
        }
        .frame(maxWidth: 340)
        .padding(LiveTranscriptDrawer.sidePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Counts from when Starting began, not from when the drawer opened.
        .task(id: startingSince) {
            isSlowStart = false
            guard let startingSince else { return }
            let remaining = LiveTranscriptDrawer.slowStartDelay - .seconds(Date().timeIntervalSince(startingSince))
            if remaining > .zero {
                try? await Task.sleep(for: remaining)
                guard !Task.isCancelled else { return }
            }
            await viewModel.checkDiskSpaceForSlowStart()
            guard !Task.isCancelled else { return }
            isSlowStart = true
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.inkSecondaryLegible)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Offers the live model when it is missing, then shows the download.
struct LiveModelDownloadPanel: View {
    let viewModel: RecordingViewModel

    var body: some View {
        VStack(spacing: Tokens.spacingSM + Tokens.spacingXS) {
            switch viewModel.liveModelState {
            case let .downloading(stage):
                HStack(spacing: Tokens.spacingSM) {
                    ProgressView().controlSize(.small)
                    caption(stage)
                }
            case let .failed(message):
                caption("The download did not finish: \(message)")
                downloadButton("Try Again")
            case .missing, .ready:
                caption("The live transcript needs its transcription model (\(LiveTranscriptionDefaults.whisperModelMegabytes) MB).")
                downloadButton("Download Model")
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.inkSecondaryLegible)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func downloadButton(_ title: String) -> some View {
        Button(title) {
            Task { await viewModel.downloadLiveModel() }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

// MARK: - Footer

private struct DrawerFooter: View {
    let viewModel: RecordingViewModel

    var body: some View {
        HStack(spacing: Tokens.spacingSM) {
            // The toggle sits over this slot.
            Color.clear.frame(width: LiveTranscriptDrawer.outset + LiveToggleButton.size - Tokens.spacingSM)
            if let status = viewModel.liveStatusText {
                // ui_design.md gives status text inkTertiary or inkSecondary;
                // neither reaches 4.5:1 on the white card, and this text
                // carries the reason live text is missing.
                Text(status)
                    .font(.monoMeta)
                    .foregroundStyle(.inkSecondaryLegible)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: Tokens.spacingSM)
            LanguageMenu(viewModel: viewModel)
        }
        .padding(.trailing, LiveTranscriptDrawer.sidePadding - Tokens.spacingXS)
    }
}
