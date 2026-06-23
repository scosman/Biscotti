---
status: complete
---

# Phase 3: Screen Rewrite + Sheet Wiring

## Overview

Replace the `modelDownloadStep` body in `OnboardingStepViews.swift` with the two-row model card
(`ModelDownloadCard.swift`), present the extracted `ManageModelsSheet` via `.sheet`, and pass
`contentMaxWidth: 560` for the `.modelDownload` step. Remove the old single-button `downloadContent`.

## Steps

1. **`OnboardingView.swift`** -- pass `contentMaxWidth: 560` for `.modelDownload`:
   - `OnboardingScaffold(step: viewModel.currentStep, contentMaxWidth: viewModel.currentStep == .modelDownload ? 560 : 520)`

2. **`ModelDownloadCard.swift`** (new file) -- build the card and row views:
   - `ModelCard` -- `VStack(spacing: 0)` with two `ModelDownloadRow`s separated by `InsetDivider(leadingInset: 48)`, `.homeCard()`, `.frame(maxWidth: 560)`.
   - `ModelDownloadRow` -- icon tile (34x34, cornerRadius 9, `Color.accentWashSoft` fill, SF Symbol `.sage`), name, why, optional extra content, trailing `DownloadControl`. Top-aligned HStack (`.top` alignment on the outer HStack).
   - `DownloadControl` -- switches on `ModelRowState`:
     - `.idle(caption)`: `GrantPill(title: "Download", systemImage: "arrow.down.circle")` + caption in `.biscottiMono(11)`, `.inkTertiary`.
     - `.downloading(.indeterminate(status))`: indeterminate sage bar (240x3) + status text.
     - `.downloading(.determinate(fraction))`: determinate sage capsule bar + "Downloading... NN%"; nil fraction -> indeterminate bar + "Downloading...".
     - `.ready`: `GrantedTag("READY")`.
     - `.insufficientDisk`: warning text "Insufficient free space on disk" with warning icon, no pill.
     - `.failed(message)`: error text + Retry pill.
   - `RecommendationLine` -- grey "Recommended . <name>" + "See all options" button with `chevron.right`.

3. **`OnboardingStepViews.swift`** -- rewrite `modelDownloadStep`:
   - Import `ModelManagementUI`.
   - New lead copy: "One-time download. AI runs locally -- nothing leaves your Mac."
   - Body -> `ModelCard(viewModel: viewModel)` instead of `downloadContent`.
   - Attach `.sheet(isPresented: $viewModel.showVariantSheet) { ManageModelsSheet(viewModel: ManageModelsViewModel(core: viewModel.appCore)) }`.
   - Remove the old `downloadContent` computed property.

4. **Reduced Motion** -- ensure progress bar animations respect `@Environment(\.accessibilityReduceMotion)`. No springs or pulsing. Use `.animation(reduceMotion ? .none : .default, ...)` guards.

## Tests

No new VM/state tests needed (Phase 2 covered the view-model logic, row-state mappers, footer matrix,
target model, on-entry preparation, and skip/advance). Phase 3 is purely view-layer: the card, rows,
download control, recommendation line, sheet presentation, and contentMaxWidth wiring. These are
SwiftUI view compositions consumed by the existing tested view model.

Build + lint verification via `hooks-mcp` confirms the views compile and integrate correctly.
