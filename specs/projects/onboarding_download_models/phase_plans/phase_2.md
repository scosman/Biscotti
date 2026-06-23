---
status: complete
---

# Phase 2: OnboardingUI view-model logic + reuse seams (no screen rewrite)

## Overview

Wire the data path for the two-row model download step while keeping the old `modelDownloadStep`
body rendering. This phase adds the `ModelRowState` enums, extends `OnboardingViewModel` with
language-model awareness and row-state mappers, generalizes `GrantPill`, adds the `contentMaxWidth`
scaffold param, and updates `Package.swift` dependencies. The package stays green throughout. The
screen rewrite comes in Phase 3.

## Steps

1. **`Package.swift`**: Add `ModelManagementUI`, `Intelligence`, `LocalLLM` to `OnboardingUI`
   target deps. Add `Intelligence`, `LocalLLM` to `OnboardingUITests` target deps.

2. **`OnboardingScaffold.swift`**: Add `var contentMaxWidth: CGFloat = 520` parameter, apply it in
   `.frame(maxWidth: contentMaxWidth)` replacing the hard-coded 520.

3. **`PermissionRow.swift`**: Generalize `GrantPill` to accept `title: String = "Grant"` and
   `systemImage: String? = nil`. Existing call sites (`GrantPill { action }`) keep compiling via
   the default args.

4. **Add `ModelRowState.swift`**: Define `RowDownloadProgress` and `ModelRowState` enums (internal
   to OnboardingUI). These are the VM output consumed by the card view in Phase 3.

5. **`OnboardingViewModel.swift`**: Add `import Intelligence` and `import LocalLLM`.
   - Add `public var appCore: AppCore { core }` (read-only, for sheet construction).
   - Add `public var showVariantSheet: Bool = false`.
   - Add `public private(set) var transcriptionDownloaded: Bool = false`.
   - Rename `startDownload()` -> `startTranscriptionDownload()`.
   - Add computed `var transcriptionReady: Bool`.
   - Add `var transcriptionInsufficientDisk: Bool`.
   - Set `requiredDiskSpaceMB` to 1500 (aligns with ~1.5 GB copy).
   - Add `var languageTargetModelID: String?` computed from active/recommended.
   - Add `var recommendedLanguageDisplayName: String?` computed.
   - Add `var languageReady: Bool` computed.
   - Add `func startLanguageDownload()`.
   - Add `func transcriptionRowState() -> ModelRowState` mapper.
   - Add `func languageRowState() -> ModelRowState` mapper.
   - Add `var bothModelsReady: Bool`.
   - Change `footerButton(for: .modelDownload)` to use `bothModelsReady`.
   - Add `private func prepareModelStep() async`, replace `checkDiskSpace()` calls in `proceed()`.
   - Update `resetForReplay()` to reset `transcriptionDownloaded` and `showVariantSheet`.

6. **`OnboardingStepViews.swift`**: Update `startDownload()` call to `startTranscriptionDownload()`.

7. **Tests**: Add new test file for row-state mapping, footer matrix, target model, on-entry
   prepare, advance/skip. Update existing tests for the rename and footer rule change.

## Tests

- **Row-state mapping (table-driven)**: transcription idle/downloading/ready/insufficientDisk/failed;
  language idle/downloading(fraction)/ready/insufficientDisk/failed; low-RAM E2B target.
- **Footer matrix**: neither ready -> skip; transcription only -> skip; language only -> skip; both
  ready -> continue.
- **Target model**: languageTargetModelID = recommended when nothing downloaded; = active when a
  model is downloaded/selected.
- **On-entry prepare**: entering `.modelDownload` sets `transcriptionDownloaded` from transcription
  fake and refreshes ModelManager.
- **Skip/advance**: both advance to `.done` regardless of readiness.
- **Existing tests**: update `startDownload()` -> `startTranscriptionDownload()` rename and footer
  rule (modelDownload now requires `bothModelsReady`).
