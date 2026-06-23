import AppCore
import BiscottiTestSupport
import Foundation
import Intelligence
import LocalLLM
import Testing
@testable import SettingsUI

@Suite("ManageModelsViewModel")
@MainActor
struct ManageModelsViewModelTests {
    // MARK: - modelChoices delegation

    @Test("modelChoices delegates to ModelManager")
    func modelChoicesDelegation() throws {
        let fixture = try makeCoreFixture(modelDownloaded: true)
        defer { fixture.cleanup() }

        let viewModel = ManageModelsViewModel(core: fixture.core)
        let choices = viewModel.modelChoices

        // Should have all catalog models
        #expect(choices.count == LLMModelCatalog.all.count)

        // The first catalog model is downloaded
        let firstChoice = choices.first
        #expect(firstChoice?.isDownloaded == true)
    }

    @Test("modelChoices reflects blocked state for low-RAM Mac")
    func modelChoicesBlockedState() throws {
        // Build a fixture with 8 GB RAM so the 12B model is not runnable.
        let fixture = try makeCoreFixture(
            modelDownloaded: false,
            hardwareRAMBytes: 8_000_000_000
        )
        defer { fixture.cleanup() }

        let viewModel = ManageModelsViewModel(core: fixture.core)
        let choices = viewModel.modelChoices

        // With 8 GB RAM, the 12B model should be blocked (cannotRun).
        let choice12b = choices.first { $0.model.id == "gemma-4-12b" }
        #expect(choice12b?.runnable == false)
        #expect(choice12b?.blockedReason == .cannotRun)

        // The smaller E2B model should still be runnable.
        let choiceE2b = choices.first { $0.model.id == "gemma-4-e2b" }
        #expect(choiceE2b?.runnable == true)
        #expect(choiceE2b?.blockedReason == nil)
    }

    @Test("modelChoices shows recommended badge on correct model")
    func modelChoicesRecommended() throws {
        let fixture = try makeCoreFixture(modelDownloaded: false)
        defer { fixture.cleanup() }

        let viewModel = ManageModelsViewModel(core: fixture.core)
        let choices = viewModel.modelChoices

        // With 32 GB RAM (default fixture), 12B should be recommended
        let recommended = choices.filter(\.isRecommended)
        #expect(recommended.count == 1)
        #expect(recommended.first?.model.id == "gemma-4-12b")
    }

    @Test("modelChoices marks selected model correctly")
    func modelChoicesSelected() async throws {
        let fixture = try makeCoreFixture(modelDownloaded: true)
        defer { fixture.cleanup() }

        // Refresh to populate selection
        await fixture.modelManager.refresh()

        let viewModel = ManageModelsViewModel(core: fixture.core)
        let choices = viewModel.modelChoices

        let selected = choices.filter(\.isSelected)
        #expect(selected.count == 1)
        #expect(selected.first?.isDownloaded == true)
    }

    // MARK: - Action delegation

    @Test("download delegates to ModelManager")
    func downloadDelegation() async throws {
        let fixture = try makeCoreFixture(modelDownloaded: false)
        defer { fixture.cleanup() }

        let viewModel = ManageModelsViewModel(core: fixture.core)

        // Before download
        #expect(fixture.modelManager.isModelAvailable == false)

        // Download via the VM
        let firstID = try #require(LLMModelCatalog.all.first?.id)
        viewModel.download(id: firstID)

        // Wait for the background Task to complete
        try await Task.sleep(for: .milliseconds(50))

        // Verify ModelManager received the download
        #expect(fixture.modelManager.isModelAvailable == true)
        #expect(fixture.modelManager.activeModelID == firstID)
    }

    @Test("choose delegates to ModelManager")
    func chooseDelegation() async throws {
        let fixture = try makeCoreFixture(modelDownloaded: false)
        defer { fixture.cleanup() }

        // Download both models
        let ids = LLMModelCatalog.all.map(\.id)
        for id in ids {
            await fixture.modelManager.downloadModel(id: id)
        }

        // First model should be selected (auto-select on first download)
        let firstID = try #require(ids.first)
        #expect(fixture.modelManager.activeModelID == firstID)

        // Choose the second model
        let secondID = try #require(ids.last)
        let viewModel = ManageModelsViewModel(core: fixture.core)
        viewModel.choose(id: secondID)

        // Wait for the background Task to complete
        try await Task.sleep(for: .milliseconds(50))

        #expect(fixture.modelManager.activeModelID == secondID)
    }

    // MARK: - Delete confirmation flow

    @Test("requestDelete sets deleteTarget")
    func requestDeleteSetsTarget() throws {
        let fixture = try makeCoreFixture(modelDownloaded: true)
        defer { fixture.cleanup() }

        let viewModel = ManageModelsViewModel(core: fixture.core)
        let choices = viewModel.modelChoices
        let firstChoice = try #require(choices.first)

        #expect(viewModel.deleteTarget == nil)

        viewModel.requestDelete(choice: firstChoice)

        #expect(viewModel.deleteTarget != nil)
        #expect(viewModel.deleteTarget?.model.id == firstChoice.model.id)
    }

    @Test("confirmDelete calls ModelManager and clears target")
    func confirmDeleteCallsManager() async throws {
        let fixture = try makeCoreFixture(modelDownloaded: true)
        defer { fixture.cleanup() }

        await fixture.modelManager.refresh()

        let viewModel = ManageModelsViewModel(core: fixture.core)
        let choices = viewModel.modelChoices
        let downloadedChoice = try #require(
            choices.first { $0.isDownloaded }
        )

        // Stage the delete
        viewModel.requestDelete(choice: downloadedChoice)
        #expect(viewModel.deleteTarget != nil)

        // Confirm the delete
        viewModel.confirmDelete()

        // Target should be cleared immediately
        #expect(viewModel.deleteTarget == nil)

        // Wait for the background Task to complete
        try await Task.sleep(for: .milliseconds(50))

        // Model should no longer be downloaded
        let refreshedChoices = viewModel.modelChoices
        let refreshed = refreshedChoices.first {
            $0.model.id == downloadedChoice.model.id
        }
        #expect(refreshed?.isDownloaded == false)
    }

    @Test("confirmDelete with no target is a no-op")
    func confirmDeleteNoTarget() throws {
        let fixture = try makeCoreFixture(modelDownloaded: true)
        defer { fixture.cleanup() }

        let viewModel = ManageModelsViewModel(core: fixture.core)
        #expect(viewModel.deleteTarget == nil)

        // Should not crash or do anything
        viewModel.confirmDelete()
        #expect(viewModel.deleteTarget == nil)
    }

    @Test("clearing deleteTarget cancels delete")
    func clearDeleteTargetCancels() throws {
        let fixture = try makeCoreFixture(modelDownloaded: true)
        defer { fixture.cleanup() }

        let viewModel = ManageModelsViewModel(core: fixture.core)
        let choices = viewModel.modelChoices
        let firstChoice = try #require(choices.first)

        viewModel.requestDelete(choice: firstChoice)
        #expect(viewModel.deleteTarget != nil)

        // Clear target (as if user cancelled)
        viewModel.deleteTarget = nil
        #expect(viewModel.deleteTarget == nil)

        // Model should still be downloaded
        let refreshedChoices = viewModel.modelChoices
        let refreshed = refreshedChoices.first {
            $0.model.id == firstChoice.model.id
        }
        #expect(refreshed?.isDownloaded == true)
    }

    // MARK: - isDownloading

    @Test("isDownloading is false when no downloads in progress")
    func isDownloadingFalse() throws {
        let fixture = try makeCoreFixture(modelDownloaded: true)
        defer { fixture.cleanup() }

        let viewModel = ManageModelsViewModel(core: fixture.core)
        #expect(viewModel.isDownloading == false)
    }

    @Test("isDownloading is true when a download is in progress")
    func isDownloadingTrue() throws {
        let fixture = try makeCoreFixture(modelDownloaded: false)
        defer { fixture.cleanup() }

        // Manually set a download state to simulate in-flight
        let firstID = LLMModelCatalog.all.first?.id ?? ""
        fixture.modelManager.downloads[firstID] = .downloading(fraction: 0.5)

        let viewModel = ManageModelsViewModel(core: fixture.core)
        #expect(viewModel.isDownloading == true)
    }
}

// MARK: - ModelBlockedReason warning text

@Suite("ModelBlockedReason")
struct ModelBlockedReasonTests {
    @Test("cannotRun warning text")
    func cannotRunWarningText() {
        let reason = ModelBlockedReason.cannotRun
        #expect(reason.warningText == "This Mac can\u{2019}t run this model")
    }

    @Test("insufficientDisk warning text")
    func insufficientDiskWarningText() {
        let reason = ModelBlockedReason.insufficientDisk
        #expect(reason.warningText == "Insufficient free space on disk")
    }
}
