---
status: complete
---

# Implementation Plan: LLM Model Selection

Ordered, dependency-first. Each phase compiles green and is reviewable on its own. Details live in
`functional_spec.md`, `ui_design.md`, and `architecture.md` (§8 has the file-by-file change list).

## Phases

- [x] **Phase 1 — LocalLLM catalog + inventory (+ E2B manual test).** Add `LLMModel` +
  `LLMModelCatalog` (the two Gemma 4 descriptors, incl. the new E2B URL) and `ModelInventory`
  (in-process `path`/`isDownloaded`/`downloadedModels`/`delete`). Keep
  `ModelDownloader.defaultModelURL`/`modelPath` for the CLI. **ManualTestApp:** extend the Local LLM
  tab (`LocalLLMScript.swift` + `WiredScripts.swift`) with **E2B coverage = one download step + one
  multi-turn (KV-cache reuse) inference step + observation** through `BiscottiLLM.xpc` on the E2B
  model (the single most demanding path — not the full suite repeated); add the new recordable step
  IDs to `manual_test_results.json` as `not-run`; update `ScriptShapeTests` for the new steps.
  Tests: catalog distinctness/lookup, inventory path/presence/filter/delete (incl. `.partial`).
  *Touches `Packages/LocalLLM` → mark existing `llm_*` manual steps `not-run`.* (Arch §1.2, §2.1, §7.)

- [x] **Phase 2 — DataStore `selectedModelID`.** Add the persisted `selectedModelID: String = ""` to
  `AppSettings`, `AppSettingsData`, and the `settings()`/`updateSettings()` mapping. Test: round-trip
  + default. *Additive, small.* (Arch §1.1.)

- [ ] **Phase 3 — Hardware + suitability (pure, additive).** `HardwareProbing` + `LiveHardwareProbe`
  (RAM + free disk only), `ModelPolicy` (per-id RAM floor + UI copy + RAM-usage copy), and
  `ModelSuitability` (`canRun`, `recommendedModelID`, `hasEnoughDisk`; 15 GB / 24 GB constants).
  Table-driven tests across RAM/disk boundaries. *No breakage.* (Arch §2.2, §3.)

- [ ] **Phase 4 — ModelManager + integration (breaking core).** Rework `ModelProviding` to
  multi-model + `LiveModelProvider`; add `ModelManager` (+ `ModelChoice`/`ModelBlockedReason`, move
  `LastFraction`); add `model: URL` to `LLMRunning.withSession` and drop `modelProvider` from
  `LiveLLMRunner`; rewire `Intelligence` (active-model guards + session call, remove its
  download-state members); wire `ModelManager` into `AppCore` (+ `onLaunch` refresh, PreviewAppCore).
  Update existing `LLMRunning`/`ModelProviding` fakes. Tests: active-model resolution + migration,
  auto-select on first download, delete→fallback/clear, select-guard, one-at-a-time, `modelChoices`
  matrix, Intelligence passes the active URL / no-ops when none. (Arch §2.3–2.7, §4, §5, §6.)

- [ ] **Phase 5 — SettingsUI row + Manage Models sheet.** Permanent `aiLanguageModelRow` (replaces the
  conditional download row); `ManageModelsSheet` + `ModelRowView` (per-state matrix, Recommended
  badge, Default/Choose, Download/Delete, warnings, progress); `ManageModelsViewModel` + delete
  confirmation; update `SettingsViewModel` (`isModelAvailable`/`activeModelDisplayName`, `load()` →
  `refresh()`). Tests: VM mapping + action delegation. (functional spec §5–7, ui_design, arch §2.6.)
