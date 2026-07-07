import AppCore
import DesignSystem
import Intelligence
import LocalLLM
import SwiftUI

// MARK: - ManageModelsViewModel

/// Thin view model for the Manage Models sheet.
///
/// Delegates all state reads to `ModelManager` (via `AppCore`) and all
/// mutations to `ModelManager` actions. Owns only the delete-confirmation
/// target (ephemeral UI state).
@MainActor @Observable
public final class ManageModelsViewModel {
    private let core: AppCore

    /// The model targeted for deletion, driving the confirmation dialog.
    /// Set by the Delete button; cleared by cancel or confirm.
    public var deleteTarget: ModelChoice?

    public init(core: AppCore) {
        self.core = core
    }

    // MARK: - Reads (delegated to ModelManager)

    /// The per-model choice matrix for the sheet rows.
    public var modelChoices: [ModelChoice] {
        core.modelManager.modelChoices()
    }

    /// Whether any model download is currently in flight.
    public var isDownloading: Bool {
        core.modelManager.downloads.values.contains {
            if case .downloading = $0 { return true }
            return false
        }
    }

    // MARK: - Actions

    /// Start downloading the model with the given id.
    public func download(id: String) {
        Task { await core.modelManager.downloadModel(id: id) }
    }

    /// Stage a model for deletion (shows the confirmation dialog).
    public func requestDelete(choice: ModelChoice) {
        deleteTarget = choice
    }

    /// Confirm and execute the staged deletion.
    public func confirmDelete() {
        guard let target = deleteTarget else { return }
        let id = target.model.id
        deleteTarget = nil
        Task { await core.modelManager.deleteModel(id: id) }
    }

    /// Select a model as the active default.
    public func choose(id: String) {
        Task { await core.modelManager.selectModel(id: id) }
    }
}

// MARK: - ManageModelsSheet

/// Sheet listing every catalog model with per-state actions (download,
/// delete, choose) and the Recommended badge. Presented from the
/// "AI Language Model" settings row and the onboarding model-download step.
public struct ManageModelsSheet: View {
    @Bindable var viewModel: ManageModelsViewModel

    @Environment(\.dismiss) private var dismiss

    public init(viewModel: ManageModelsViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spacingMD) {
            // Header
            Text("AI Language Model")
                .font(.headline)

            Text(
                "Choose the model used to summarize your meetings. It runs entirely on your Mac."
            )
            .font(Tokens.metadataFont)
            .foregroundStyle(Tokens.secondaryText)

            // Model rows
            VStack(spacing: Tokens.spacingSM) {
                ForEach(viewModel.modelChoices) { choice in
                    ModelRowView(
                        choice: choice,
                        isDownloading: viewModel.isDownloading,
                        onDownload: { viewModel.download(id: choice.model.id) },
                        onDelete: { viewModel.requestDelete(choice: choice) },
                        onChoose: { viewModel.choose(id: choice.model.id) }
                    )
                }
            }

            // Footer
            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(Tokens.spacingMD * 1.5)
        .frame(width: 480)
        .confirmationDialog(
            deleteDialogTitle,
            isPresented: showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                viewModel.confirmDelete()
            }
        } message: {
            Text(deleteDialogMessage)
        }
    }

    // MARK: - Delete confirmation helpers

    private var showDeleteConfirmation: Binding<Bool> {
        Binding(
            get: { viewModel.deleteTarget != nil },
            set: { show in
                if !show { viewModel.deleteTarget = nil }
            }
        )
    }

    private var deleteDialogTitle: String {
        guard let target = viewModel.deleteTarget else { return "" }
        return "Delete \(target.model.displayName)?"
    }

    private var deleteDialogMessage: String {
        guard let target = viewModel.deleteTarget else { return "" }
        // Integer division is fine here — catalog models are whole-GB sizes.
        let sizeGB = target.model.approxDownloadBytes / 1_000_000_000
        return "This frees about \(sizeGB) GB. You can download it again anytime."
    }
}

// MARK: - ModelRowView

/// A single model row in the Manage Models sheet.
///
/// Renders the per-state matrix from `ModelChoice` (ui_design §2.2):
/// blocked (not runnable), insufficient disk, downloadable, downloading,
/// failed, downloaded+selected, downloaded+not-selected.
struct ModelRowView: View {
    let choice: ModelChoice
    /// Whether any model (possibly another) is currently downloading.
    let isDownloading: Bool
    let onDownload: () -> Void
    let onDelete: () -> Void
    let onChoose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spacingXS) {
            // Line 1: name + recommended badge + selection control
            HStack {
                Text(choice.model.displayName)
                    .fontWeight(.medium)

                if choice.isRecommended {
                    recommendedBadge
                }

                Spacer()

                selectionControl
            }

            // Line 2: description + primary action
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    descriptionOrProgress
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                primaryAction
            }
        }
        .padding(Tokens.spacingSM)
        .background(Color.neutralChip.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: Tokens.buttonRadius))
        .opacity(choice.blockedReason == .cannotRun ? 0.5 : 1.0)
    }

    // MARK: - Recommended badge

    private var recommendedBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "star.fill")
                .font(.caption2)
            Text("Recommended")
                .font(.caption)
        }
        .foregroundStyle(.sage)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(Color.sage.opacity(0.15))
        )
    }

    // MARK: - Selection control (trailing, line 1)

    @ViewBuilder
    private var selectionControl: some View {
        if choice.blockedReason == .cannotRun {
            EmptyView()
        } else if choice.isDownloaded, choice.isSelected {
            // Default indicator
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.sage)
                Text("Default")
                    .font(Tokens.metadataFont)
                    .foregroundStyle(Tokens.secondaryText)
            }
        } else if choice.isDownloaded, choice.runnable {
            Button("Choose Model") {
                onChoose()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    // MARK: - Description / progress / warning (left column, lines 2-3)

    /// The model description text, styled for left-aligned wrapping.
    private var descriptionText: some View {
        Text(choice.description)
            .font(Tokens.metadataFont)
            .foregroundStyle(Tokens.secondaryText)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var descriptionOrProgress: some View {
        // Guard cannotRun first — non-runnable models show only the
        // description + warning, never download/failure progress.
        if choice.blockedReason == .cannotRun {
            descriptionText
            warningLabel(for: .cannotRun)
        } else {
            switch choice.downloadState {
            case let .downloading(fraction):
                descriptionText
                if let fraction {
                    ProgressView(value: fraction)
                    Text("Downloading\u{2026} \(Int(fraction * 100))%")
                        .font(Tokens.metadataFont)
                        .foregroundStyle(Tokens.secondaryText)
                } else {
                    ProgressView()
                        .controlSize(.small)
                    Text("Downloading\u{2026}")
                        .font(Tokens.metadataFont)
                        .foregroundStyle(Tokens.secondaryText)
                }

            case let .failed(message):
                descriptionText
                Text("Download failed: \(message)")
                    .font(Tokens.metadataFont)
                    .foregroundStyle(.signalRedText)

            default:
                descriptionText

                // Warnings (e.g. insufficientDisk)
                if let reason = choice.blockedReason {
                    warningLabel(for: reason)
                }
            }
        }
    }

    private func warningLabel(for reason: ModelBlockedReason) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
            Text(reason.warningText)
                .font(.caption)
        }
        .foregroundStyle(Tokens.warningChipText)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(Tokens.warningChipFill)
        )
    }

    // MARK: - Primary action (trailing, line 2)

    @ViewBuilder
    private var primaryAction: some View {
        // Check cannotRun first — a non-runnable model should never show
        // Retry/Download/Choose regardless of download state.
        if choice.blockedReason == .cannotRun {
            EmptyView()
        } else {
            switch choice.downloadState {
            case .downloading:
                // No action button while downloading
                EmptyView()

            case .failed:
                Button("Retry") {
                    onDownload()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

            default:
                if choice.isDownloaded {
                    Button("Delete") {
                        onDelete()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    // Not downloaded — Download button
                    Button("Download") {
                        onDownload()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(
                        choice.blockedReason == .insufficientDisk
                            || (isDownloading && !isThisModelDownloading)
                    )
                }
            }
        }
    }

    private var isThisModelDownloading: Bool {
        if case .downloading = choice.downloadState { return true }
        return false
    }
}

// MARK: - ModelBlockedReason + warning text

extension ModelBlockedReason {
    /// The user-facing warning string for this blocked reason.
    var warningText: String {
        switch self {
        case .cannotRun:
            "This Mac can\u{2019}t run this model"
        case .insufficientDisk:
            "Insufficient free space on disk"
        }
    }
}
