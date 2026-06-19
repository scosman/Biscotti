---
status: complete
---

# Architecture: UI Batch

These are small, mostly-local changes to existing SwiftUI views/view-models and (for items 5a, 6, 7) a thin slice of model/engine/AppKit glue. No new packages, no new third-party dependencies, no schema migration beyond two additive changes noted below. Everything fits here — no per-component design docs.

Conventions: Swift-package-first; the app target stays thin. UI in `Packages/BiscottiKit/Sources/*`; transcription engine in `Packages/Transcription`. Build/test via `hooks-mcp` (the agent Bash sandbox can't compile Swift).

---

## Item 1 — Record button size

- **Files:** `AppShellUI/AppShellView.swift` (idle Record button, ~line 89) and/or `DesignSystem/JoinRecordButtonStyle.swift` (`ToolbarRecordButtonStyle`, ~line 45).
- **Approach:** bump the idle button one control-size step. Cleanest options, pick what reads best next to the `RecordingToolbarButton` (which is `height: 34`): apply `.controlSize(.large)` to the idle `Button`, or increase the style's vertical padding / add an explicit `.frame(height:)` in `ToolbarRecordButtonStyle` so idle and recording states are near-equal height. Keep fill/label/icon.
- **Risk:** trivial/visual.

## Item 2 — Reduce "RECORDING" emphasis (2 commits)

- **Files:** `AppShellUI/AppShellView.swift`, `AppShellUI/AppShellViewModel.swift`, color tokens in `DesignSystem/Color+Theme.swift` (read-only reference).
- **2a (sidebar normalize):** in `RecordingNowSection` (~line 446) replace the red `.background(... recordingTintSoft/Strong)` with the normal-row pattern (`route == .recording ? Tokens.accentWashStrong : Color.clear` in a `RoundedRectangle(cornerRadius: 4)`), remove the `recordingOutlineStrong` `.overlay`, and change the "Recording" subtitle color from `Color.signalRed` to `Tokens.secondaryText`/`.inkSecondary`. Mirror the existing `homeRow`/`pastMeetingsRow` styling.
- **2b (disable toolbar button on recording page):** add `var isOnRecordingPage: Bool { core.route == .recording }` to `AppShellViewModel` (next to `isHome`, ~line 185), and apply `.disabled(viewModel.isOnRecordingPage)` to `RecordingToolbarButton` (the recording-state branch, ~line 87). Matches the Home button's `.disabled(viewModel.isHome)`.
- **Risk:** low.

## Item 3 — "See All" as the list's last row

- **Files:** `HomeUI/HomeView.swift` (`HomePastSection`, ~line 304), `HomeUI/HomeViewModel.swift`.
- **Approach:** remove the trailing "See all" `Button` from the header `HStack` (leave only the kicker label). Expose `var pastMeetingsCount: Int { core.summaries.count }` on `HomeViewModel`. In `pastCard`, after the last `pastRow`, add an `InsetDivider()` then a `Button(.plain) { viewModel.showMeetings() }` whose label is an `HStack { Text("See All"); Spacer(); Text("\(count)").foregroundStyle(.inkSecondary); Image(systemName: "chevron.right") }` with padding matching `pastRow`. Only render the See-All row inside the non-empty card (not in the "No recordings yet" empty state).
- **Risk:** low.

## Item 4 — Play links start playback

- **Files:** `MeetingDetailUI/MeetingDetailViewModel.swift` (add `seekAndPlay(to:)`, reuse `seek`/`playPause`/`startPlaybackTicker`), `MeetingDetailUI/MeetingDetailView.swift` (two `onSeek` closures, ~lines 243 & 573).
- **Approach:** add `func seekAndPlay(to time: TimeInterval)` that calls the existing seek then, if `audioPlayer?.isPlaying == false`, starts playback + ticker (reuse the play branch of `playPause()` to avoid duplicating ticker logic). Wire both `onSeek` closures and `applySeekIfReady()` (~line 578) to `seekAndPlay`. Leave `seek(to:)` pure. No scrubber calls `seek(to:)` today, so no other call sites are affected.
- **Risk:** low.

## Item 5 — Transcribing UI (2 commits)

- **5a (suppress spurious download phase):**
  - **Files:** `BiscottiKit/Sources/TranscriptionService/TranscriptionService.swift` (`executeJob`'s initial `.downloadingModel(message: "Preparing…")`, `downloadModels`), `JobStatus`, the `MeetingDetailViewModel.displayState` mapping, and/or `Packages/Transcription/Sources/Transcription/InProcessTranscriptionEngine.swift` (the `status("Downloading …")` emit sites).
  - **Approach (keep simple — pick one):** (1) **delay-gate** — only show the "Downloading…model" subtitle after the download phase has been active ~5s (cache-hit loads finish well under that, so it never flashes; real downloads still show it); or (2) **real-signal-gate** — only show `.downloadingModel` once a genuine download-progress signal (< 1.0) fires. Do **not** build elaborate per-SDK disk-cache path detection. Whichever is chosen, the observable contract is: cached ⇒ "Transcribing…" with no download subtitle/flash; missing ⇒ download phase still appears.
  - **Research sub-task (report at review):** the user assumed the model-readiness *check* is instant. Investigate (code-level) whether `ensureModelsDownloaded` → WhisperKit/SpeakerKit init does blocking disk/compile/network work on a **cache hit**. If it's slow, evaluate an **optimistic flow** — *assume cached → attempt to load/transcribe → fall into the download path only on failure/absence* — to avoid paying a "check" cost on the common cached path. Implement it only if small and clearly better; otherwise document + recommend as follow-up. Empirical timing needs a human/`test-ai` run (agent can't run model tests).
  - **Manual tests:** edits to `Packages/Transcription` ⇒ mark `tx_*` recordable steps `not-run` in that commit.
  - **Risk:** medium. The simple gate is low-risk; the research/optimistic-migration is the open question — keep it scoped.
- **5b (centered transcribing layout):**
  - **Files:** `MeetingDetailUI/MeetingDetailView.swift` (`centeredStatus`, ~line 550, and the `.processing` branch of `transcriptTabContent`). Prefer a **new dedicated centered view** here rather than altering the shared `DesignSystem/StatusRow.swift` (used by completed/other states).
  - **Approach:** a center-aligned `VStack` — larger `ProgressView()` (`.controlSize(.large)` or scaled), larger centered "Transcribing…" text, optional subtitle on its **own centered line** below — kept vertically+horizontally centered. Vertical center-aligned stacking means subtitle changes don't shift horizontally.
  - **Risk:** low.

## Item 6 — Global ⌘⇧R + settings toggle

- **New file (in-repo Carbon wrapper):** a `GlobalHotKey` type (likely in the App target or a small AppKit-glue spot in `BiscottiKit`/`AppCore` consistent with where app-lifecycle glue lives) that wraps Carbon `RegisterEventHotKey` + `InstallEventHandler`, exposes register/unregister, and invokes a Swift callback on fire. Must unregister cleanly (no leaks).
- **Model:** add `globalRecordShortcutEnabled: Bool = true` to `DataStore/Models/AppSettings.swift` (additive, defaulted — no migration concerns for a defaulted SwiftData property).
- **Settings UI:** add a toggle to `SettingsUI/SettingsView.swift` General section + read/write via `SettingsViewModel` (`core.store.updateSettings { … }`), posting a change notification like the existing `exitOnWindowClose` pattern.
- **Wiring:** in `App/BiscottiApp.swift` (`AppDelegate`, after `buildCore()`), register the hotkey on launch iff the setting is ON; the callback calls `core?.startRecording()`. Observe the settings-change notification to register/unregister live. Guard against double-start while already recording (rely on `startRecording`'s existing guards).
- **Risk:** medium (Carbon glue + lifecycle/teardown). Keep the wrapper small; no third-party dep.

## Item 7 — Multi-select + delete (2 commits)

- **7a (selection model → Set):**
  - **Files:** `AppCore/AppCore.swift` (`meetingsSelection: UUID?` → `Set<UUID>` at ~line 115; `selectFromList`, `autoSelectTopResult`, `neighborID`/delete selection logic), `MeetingListUI/MeetingListViewModel.swift` (`selectedID`/`select(_:)` → set), `MeetingListUI/MeetingListView.swift` (`List(selection:)` → `Binding<Set<UUID>>`), `AppShellUI/AppShellView.swift` (`MeetingsSplitView` detail routing) + `AppShellViewModel` accessors.
  - **Approach:** set-based selection enables shift/⌘ multi-select natively. Detail routing: `count == 1` → `MeetingDetailView(for: theID)`; `count > 1` → an "N meetings selected" placeholder built like the existing `ContentUnavailableView` empty state **plus a Delete button** (invokes the 7b confirm+delete flow); `count == 0` → existing "No Meeting Selected". Audit every reader of the old optional id and convert to "exactly one" semantics.
  - **Risk:** medium (touches several call sites + AppCore state used widely).
- **7b (delete key + confirm + multi-delete):**
  - **Files:** `MeetingListUI/MeetingListView.swift` (`.onDeleteCommand`/`onKeyPress(.delete)` + confirmation `.alert`/`.confirmationDialog`), `AppCore/AppCore.swift` (batch `deleteMeetings(_ ids:)` or loop `deleteMeeting`, + post-delete selection resolution adapted for sets), and the "N selected" placeholder's Delete button from 7a.
  - **Approach:** Delete key (and placeholder Delete button) → confirmation with singular/plural copy → on confirm, delete all selected (audio files + DB rows via existing `deleteMeeting` internals), then resolve selection (clear or neighbor). Empty selection ⇒ no-op. Existing detail-menu single delete unchanged.
  - **Risk:** medium (data deletion path; be careful with post-delete selection + open detail pane).

---

## Cross-cutting decisions

- **No new dependencies / no bundle-ID or signing changes.** Item 6's global hotkey is in-repo Carbon glue (no `KeyboardShortcuts`/`HotKey` package), chosen to avoid a TCC permission prompt and a third-party dep.
- **Selection state is centralized in `AppCore.meetingsSelection`.** Item 7a's migration from `UUID?` to `Set<UUID>` is the largest blast radius; do it as its own commit and update all consumers in one pass.
- **Manual-test staleness:** only item 5a edits a tracked package (`Transcription`) → mark `tx_*` recordable steps `not-run` in that commit. No other item edits `Transcription` or `AudioCapture`.
- **Each phase ends green** on `lint`+`test` (and `build_app` where UI/app glue changed), run via `hooks-mcp`. Per-item commits for rollback granularity.
