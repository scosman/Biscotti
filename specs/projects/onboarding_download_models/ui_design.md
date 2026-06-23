---
status: complete
---

# UI Design: Onboarding — Download Models (V2)

Reconciles the design agent's V2 spec with the shipped onboarding components and the Decisions in
`functional_spec.md` §9. Only the `.modelDownload` step body changes. Reuse shipped components
verbatim where noted — do not invent new chrome.

## Layout (top → bottom), inside the existing `OnboardingScaffold`

1. **Title** — "Download Local AI Models", `.biscottiSerif(34)`, `.ink` (unchanged from today).
2. **Lead** — "One-time download. AI runs locally — nothing leaves your Mac." `.system(16)`,
   `.inkSecondary`, `maxWidth ~430`, `.padding(.top, 12)`. (Drops the inline "~1.5 GB"; sizes now
   live per row.)
3. **Model card** — the two-row card, `.padding(.top, 20–24)` (match the Grant-access card offset).
4. **Footer** — `footerButton` (Skip / Continue), `.padding(.top, 24)`.

## The card

Reuse the **Grant-access card chrome**: `.homeCard()` + `.frame(maxWidth: 560)` (Decision
**D2** — 560 per the design), two rows separated by `InsetDivider(leadingInset: 48)` — the
same divider/inset the permission card uses. Rows are **top-aligned** (the language row has a third
line).

The scaffold's content column is widened to 560 for this step only: `OnboardingScaffold` gains a
`contentMaxWidth` parameter (default 520) and `OnboardingView` passes 560 when the step is
`.modelDownload`. All other steps stay at 520.

```
┌───────────────────────────────────────────────┐  ← .homeCard(), maxWidth 560
│ [tile] Transcription & Speaker ID   <control>  │
│        Turns speech into text and labels        │
│        who's speaking.                          │
│ ───────────────────────────────────────────── │  ← InsetDivider(leadingInset: 48)
│ [tile] Language Model               <control>  │
│        Meeting summaries, speaker matching,     │
│        and automatic titles.                    │
│        Recommended · Gemma 4 E2B  See all ›     │
└───────────────────────────────────────────────┘
```

## The row

Mirror the shipped `PermissionRow` skeleton (icon tile + name + "why" + trailing control), but
**top-aligned** and with the language row's optional third line. Reuse the same icon tile (34×34,
`cornerRadius 9`, `Color.accentWashSoft` fill, SF Symbol tinted `.sage`).

- **Icon**: transcription → `waveform`; language → `sparkles`.
- **Name**: `.system(14.5, weight: .semibold)`, `.ink`.
- **Why**: `.system(12.5)`, `.inkSecondary`, wraps before the trailing control.
- **Trailing control**: the per-state download control (below), top-aligned.

Reuse decision: `PermissionRow` is currently parameterized for a single trailing control and an
optional denial slot. The two model rows may either reuse `PermissionRow` (if the trailing/third-line
needs fit its generics) or be a small sibling row view in `OnboardingUI` that copies its metrics. Pick
whichever is least code at implementation time; keep the metrics identical to `PermissionRow`.

## Trailing download control (per class)

A top-aligned trailing column, `alignment: .trailing`. States:

- **Idle**: a **Download** pill (reuse `GrantPill` / `JoinRecordButtonStyle`, generalized to take a
  title + leading SF Symbol — label "Download", symbol `arrow.down.circle`) with a **size caption**
  below it in `.biscottiMono(11)`, `.inkTertiary` — "~1.5 GB" (transcription) / the target model's
  size, e.g. "~3.2 GB" (language). `spacing: 6`.
- **Downloading**:
  - **Transcription** (Decision **D1**): an **indeterminate** sage capsule bar (the existing
    240×3 track + sliding fill idiom from today's `downloadContent`) + the engine's status text in
    `.biscottiMono(11)`, `.inkSecondary`.
  - **Language**: a **determinate** sage capsule bar bound to `downloads[id]` fraction + a
    `.biscottiMono` caption "Downloading… NN%". If fraction is nil, fall back to the indeterminate
    bar + "Downloading…". Reuse the header's sage capsule style (or a small shared bar view).
- **Ready**: the shipped `GrantedTag`, labeled **"READY"** (Decision **D4**). No caption.
- **Blocked — insufficient disk**: no pill; show a warning ("Insufficient free space on disk") in
  the warning treatment used elsewhere (e.g. the `Banner`/warning chip idiom). Download disabled.
- **Failed**: error text + a Retry control (reuse the small bordered Retry idiom).

## Recommendation line (language row only)

Shown **only in the idle state**. Two pieces on one row, `spacing ~10`, `.padding(.top, 6)`:
- "Recommended · \(displayName of `recommendedModelID()`)" — `.system(12.5)`, `.inkSecondary`.
- "See all options" — `.system(12.5, weight: .semibold)`, `.inkSecondary`, trailing
  `chevron.right` (11pt). `.buttonStyle(.plain)`. Tap → `viewModel.showVariantSheet = true`.
- **No icon/chip** next to "Recommended".

## "See all options" sheet

`.sheet(isPresented: $viewModel.showVariantSheet)` presenting the existing
`ManageModelsSheet(viewModel: ManageModelsViewModel(core: <appCore>))` — identical to Settings.
The view model needs access to the `AppCore` (expose it from `OnboardingViewModel`, mirroring how
`SettingsViewModel` exposes `appCore`).

## Footer

Reuse the existing `footerButton` computed view. Its branch is driven by
`viewModel.isCurrentStepComplete`, which for `.modelDownload` now means `bothReady`
(`transcriptionReady && core.modelManager.isModelAvailable`). Idle/downloading → "Skip"; both ready →
"Continue". Keep the fixed `minHeight: 40` so the swap doesn't shift layout. Respect Reduced Motion
(no springs) — consistent with the shipped step transition.

## Reduced Motion

No pulsing/springs. State swaps are instant under `accessibilityReduceMotion`. The progress bars do
not pulse; the language bar simply reflects fraction.
