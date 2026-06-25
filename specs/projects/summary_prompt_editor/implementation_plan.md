---
status: complete
---

# Implementation Plan: Custom Summary Prompt

Ordered, dependency-first. Each phase is one reviewable unit and ends green on
`make test` / `make lint` (via `hooks-mcp`). See `functional_spec.md`,
`ui_design.md`, and `architecture.md` for details — this is just the build order.

## Phases

- [x] **Phase 1 — Data + generation wiring (headless).**
  Persist and thread the editable prompt end-to-end, with **default output byte-identical**.
  - `AppSettings.summaryPrompt` (+ init) and `AppSettingsData.summaryPrompt` (DataStore). [arch §1.1–1.2]
  - `applyGeneratedSummary(_:for:markEdited:)` flag (default false). [arch §1.3]
  - `IntelligencePrompts.defaultSummaryPrompt`; parameterize `summaryOnlyFirstUser(…summaryInstructions:)` and the follow-up. [arch §2.1–2.2]
  - Thread `summaryInstructions` + `markSummaryEdited` through `buildFirstUserContent`, `contextBudgetFollowUps`, `MeetingAnalyzer.Context`/`runSummaryTurn`, `runAnalysisSession`. [arch §2.3]
  - `AISettings.summaryPrompt` + `AppCore+Live` empty→default resolution; `runAnalysis(…summaryPromptOverride:markResultEdited:)`; `runAutoEnhancements` uses saved prompt. [arch §2.4]
  - `AppCore`: `defaultSummaryPrompt`, `effectiveSummaryPrompt()`, `saveSummaryPrompt()` (clear-to-default). [arch §3]
  - Update existing `AISettings` / `MeetingAnalyzer.Context` constructors in tests/fakes; add the default-unchanged guard + the generation/persistence tests. [arch §7]

- [ ] **Phase 2 — `SummaryPromptUI` module + the editor field.**
  The reusable, callback-driven sheet — no entry points wired yet.
  - New `SummaryPromptUI` target (+ tests) in `Packages/BiscottiKit/Package.swift`, deps DesignSystem + MarkdownEditorUI. [arch §5.3]
  - `MarkdownPromptField` in `MarkdownEditorUI` — engine control used directly, bounded/scrolling, optional JetBrains Mono, clear background for host chrome. [arch §4.3]
  - `SummaryPromptModel` (working/initial/default text, mode, also-save; pure helpers: empty/unsaved/isDefault/added/append/restore), `SummaryPromptMode`, `MeetingReference`, `PromptExample` blocks. [arch §4.1–4.4]
  - `SummaryPromptSheet` View per `ui_design.md` (kicker/serif title/subtitle/+chip, PROMPT label, editor + field chrome, empty caption, ADD EXAMPLE chips in `FlowLayout`, per-meeting toggle + replace warning, footer Restore/Cancel/primary, confirmations). Previews.
  - Unit tests for `SummaryPromptModel` logic.

- [ ] **Phase 3 — Wire entry points.**
  - Settings (Global): `Summary Prompt` row in `aiEnhancementsSection` (`.disabled(!aiAnalysisEnabled)`) + `Customize…` → sheet; `SettingsViewModel` load-effective + `onSave`→`core.saveSummaryPrompt`. [arch §5.1]
  - Meeting detail (Per-meeting): overflow **Regenerate Summary** → presents the sheet; `MeetingDetailViewModel.regenerate(withPrompt:alsoSave:)` (compute `markEdited`, optional save, `runAnalysis` override) ; remove the old regenerate-confirm path; first-run **Generate Summary** unchanged. [arch §5.2]
  - `SettingsUI` + `MeetingDetailUI` depend on `SummaryPromptUI`. [arch §5.3]
  - View-model wiring tests (markEdited across the three cases).

## Manual test note
This touches `Intelligence`/summary generation but **not** the gated manual-test libraries
(`Transcription`, `AudioCapture`, `LocalLLM` / `BiscottiLLM`), so no
`manual_test_results.json` resets are required. The editor field and both sheet flows
should be exercised in the next on-hardware pass (not unit-tested — AppKit text view).
