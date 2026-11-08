---
status: draft
---

# Architecture: Import Audio

How the feature in `functional_spec.md` / `ui_design.md` is built. This doc covers the topology, the data-model changes, single-track transcription, the post-processing queue, the AppCore wiring and the test strategy. Two component docs hold the detailed internals:

- [`components/audio_import.md`](components/audio_import.md): the `AudioImport` module (classification, conversion, metadata, import session controller).
- [`components/import_ui.md`](components/import_ui.md): the `ImportUI` module (window drop target, drop overlay, Import screen) and the shell/App wiring.

---

## 1. Module map

### 1.1 New modules (BiscottiKit targets)

| Module | Kind | Responsibility | Depends on |
|---|---|---|---|
| `AudioImport` | library | File-type classification. AVFoundation conversion to the standard ADTS AAC format. Media-date reading. The session-long import list and its serial worker. Creating the imported meeting in `DataStore`. No AppKit, no SwiftUI. | `DataStore`, `AudioCapture` (product, for `EncoderSettings.voice`), AVFoundation, AudioToolbox, UniformTypeIdentifiers |
| `ImportUI` | library | The AppKit window drop target (incl. file promises), the drop overlay view, the Import screen and its view model. | `AppCore`, `AudioImport`, `DataStore`, `DesignSystem`, `Formatting` |
| `AudioImportTests`, `ImportUITests` | test targets | see §9 | + `BiscottiTestSupport` |

`AudioImport` only *reads* `AudioCapture`'s public `EncoderSettings` (preset values, `outputASBD()`, `applyBitRate(to:bitRate:)`). It does **not** modify `Packages/AudioCapture`, so the `ac_*` manual tests are unaffected.

### 1.2 Changed components

| Component | Change |
|---|---|
| `Packages/Transcription` | The mic and system paths become optional end to end (engine protocol, `Transcriber`, XPC request, `AudioLoading`, `SpeakerAnalyzer`, CLI). §3. **Touches the package, so mark every `tx_*` step `not-run`** in `ManualTestApp/Results/manual_test_results.json` (recordable steps only, per CLAUDE.md). |
| `XPCServices/BiscottiTranscriber` | Passes the optional paths through. No protocol change (the payload is JSON). |
| `DataStore` | `Meeting.titleIsPlaceholder`, the title policy, `createImportedMeeting`, optional-pair `audioPaths`, the read-model field. §2. |
| `TranscriptionService` | The `Transcribing` seam takes optional URLs. The resolve step accepts single-track meetings. §3.4. |
| `Intelligence` | The two AI-title gates call `Meeting.isAIReplaceableTitle(...)`. §2.2. |
| `AppCore` | `Route.importing`, `PostProcessingQueue`, owns `AudioImportController`, the import API, auto-navigation, the import-panel request flag. §4, §5. |
| `MeetingDetailUI` | Retry and Re-transcribe go through the queue. Waiting state. §6. |
| `AppShellUI` | Import route, sidebar "Imported" row, drop target + overlay at the root, `.fileImporter`. See `components/import_ui.md`. |
| `DesignSystem` | `dropVeil`, `controlStroke`, `BezelButtonStyle` (`ui_design.md` §1). |
| `Formatting` | `TimeFormatting.dateAndTime(_:)`. |
| `App` (`BiscottiApp.swift`) | File > Import Audio File… command. |
| `voiceprint-cli` | Backfill accepts single-track candidates. |
| `BiscottiTestSupport` | `FakeTranscriber` records optional paths. `CoreFixture.createImportedMeetingWithAudio(...)`. A fake converter. |

### 1.3 Dependency DAG additions

```
AudioCapture(pkg) ─┐
DataStore ─────────┴─► AudioImport ─► AppCore ─► ImportUI ─► AppShellUI ─► App
                                        ▲                       ▲
                       DesignSystem, Formatting ────────────────┘
```

`App/project.yml` needs **no** new product: the App target talks to `AppCore` (already linked) and `AppShellUI` (already linked). The open panel is SwiftUI `.fileImporter` inside `AppShellUI` (§5.3).

---

## 2. Data model (`DataStore`)

### 2.1 `Meeting.titleIsPlaceholder`

```swift
/// `true` while the title is a machine-generated placeholder (e.g.
/// "Imported from X.m4a") that AI titling may replace, exactly like
/// `Meeting.defaultTitle`. Cleared whenever a real title lands (AI, user,
/// calendar event). Additive field -- defaults false, no migration needed.
public var titleIsPlaceholder: Bool = false
```

This follows the existing additive-field pattern (`recordingDuration`, `externalID`): a lightweight SwiftData migration with a default, and no schema-version bump.

### 2.2 Title policy (single source of truth)

`Meeting.swift`:

```swift
public extension Meeting {
    /// Whether AI titling may replace this title.
    static func isAIReplaceableTitle(
        title: String, editedTitle: Bool, titleIsPlaceholder: Bool
    ) -> Bool {
        !editedTitle && (title == defaultTitle || titleIsPlaceholder)
    }
}
```

Call sites switch to it:

| Site | Change |
|---|---|
| `DataStore.applyGeneratedTitle(_:for:)` | Gate: `Meeting.isAIReplaceableTitle(...)`. When it applies: `meeting.titleIsPlaceholder = false`. `editedTitle` stays false, as today. |
| `Intelligence.swift` (`doTitle`, ~line 217) | `Meeting.isAIReplaceableTitle(title: detail.title, editedTitle: detail.editedTitle, titleIsPlaceholder: detail.titleIsPlaceholder)` |
| `MeetingAnalyzer.swift` (`doTitle`, ~line 319) | Same. |
| `DataStore.setTitle(_:for:)` (user rename) | Also sets `titleIsPlaceholder = false`. |
| `DataStore.applyEventTitle(_:for:)` | When it applies (not edited): also sets `titleIsPlaceholder = false`. |

`MeetingDetailData` gains `public let titleIsPlaceholder: Bool` (init default `false`), populated in `meetingDetail(id:)`. Grep for any other `== Meeting.defaultTitle` gate during implementation. Today there are exactly these three.

### 2.3 `createImportedMeeting`

`DataStore+Import.swift` (new file):

```swift
public extension DataStore {
    /// Inserts a fully-formed imported meeting in ONE save: the meeting
    /// (caller-supplied id, so the audio directory can be named before
    /// insert), its single present `.system` audio ref, duration and the
    /// placeholder-title flag. Throws on save failure (nothing inserted).
    func createImportedMeeting(
        id: UUID,
        title: String,
        start: Date,
        duration: TimeInterval,
        audioPath: String,
        audioByteSize: Int64
    ) throws
}
```

- Fields: `Meeting(id: id, title: title, startDate: start, endDate: start + duration)`. `createdAt` = now (the default).
- `recordingDuration = duration`, `titleIsPlaceholder = true`, `editedTitle = false`.
- Audio: `audioFiles = [AudioFileRef(role: .system, path: audioPath, byteSize: audioByteSize, isPresent: true)]`.
- Search index: no explicit work. It follows `createMeeting`'s lazy-sync behavior (the index syncs on the next search).

### 2.4 Optional-pair `audioPaths`

```swift
/// Returns the present audio file URLs for a meeting, or nil when the
/// meeting is missing or has NO present audio ref. A single-track meeting
/// (imports) returns one non-nil URL.
func audioPaths(meetingID: UUID) throws -> (mic: URL?, system: URL?)?
```

The only production caller is `TranscriptionService.resolveAudioPaths`. Update any tests that destructure it.

`backfillCandidates()` already yields optional URLs. `voiceprint-cli/BackfillCommand.processOne` changes its guard to "at least one of mic/system". `BackfillError.missingAudioPath` is thrown only when both are nil.

---

## 3. Single-track transcription (`Packages/Transcription` + `TranscriptionService`)

The engine already diarizes the **merged mono** signal, and `AudioMerger.merge` already handles an empty stream (`(false, true)` → system only). The only blocker is that every layer requires two file paths and `AudioLoading.loadSamples` throws on a missing file. The change makes "absent" a first-class value instead of a silent placeholder file.

### 3.1 Engine layer

| File | Change |
|---|---|
| `TranscriptionEngine.swift` | `func processAudio(micPath: String?, systemPath: String?, customVocabulary: [String]) async throws -> TranscriptResult`. Update the doc: "At least one path is required; a nil path means that stream was not recorded." |
| `AudioLoading.swift` | `static func loadAndMerge(micPath: String?, systemPath: String?) throws -> MergeResult`. If both are nil: `throw TranscriptionError.invalidInput("At least one audio stream is required")`. Load each non-nil path with the existing `loadSamples` (which still throws for a nil-but-expected missing file). Pass `[]` for an absent stream to `AudioMerger.merge`. |
| `InProcessTranscriptionEngine.swift` | Thread the optionals through `processAudio` → `loadAndMergeAudio`. |
| `XPCProcessRequest.swift` | `public let micPath: String?` and `public let systemPath: String?`. Synthesized `Codable` decodes a missing key as nil, so the payload stays compatible. |
| `XPCEngineAdapter.swift` | Builds the request with the optionals. |
| `XPCServices/BiscottiTranscriber/main.swift` | Passes `request.micPath` / `request.systemPath` through unchanged. |
| `Transcriber.swift` | `processAudio(mic: URL?, system: URL?, customVocabulary:)` and `reTranscribe(mic: URL?, system: URL?, …)`. Replace the "pass an empty/silent file" doc text. |
| `SpeakerAnalyzer.swift` | `analyze(micPath: String?, systemPath: String?)`. |
| `transcribe-cli` | `--mic` and `--system` become optional `String?`. Validation: at least one is required (`ValidationError("Provide --mic, --system, or both.")`). Update the help text. |

### 3.2 Why not a silent mic file

At 64 kbps, a silent mic track costs about 29 MB per hour, it's fake data that MCP and export would report as a real "microphone" file, and the Transcriber doc already treats it as a workaround. Making the absence explicit is a small, contained change.

### 3.3 Tests (Transcription package)

- `AudioLoadingTests.loadAndMerge_systemOnly`: writes a real short AAC or WAV to a temp dir, uses `micPath: nil`, and checks sample count ≈ the system file's.
- `AudioLoadingTests.loadAndMerge_micOnly`: the mirror case.
- `AudioLoadingTests.loadAndMerge_bothNil_throwsInvalidInput`.
- `XPCProcessRequestTests.roundTrip_nilMic`, and `decode_missingMicKey_isNil` (raw JSON without `micPath`).
- Existing two-track tests keep passing unchanged (non-nil paths).

### 3.4 `TranscriptionService`

- `Transcribing.processAudio(mic: URL?, system: URL?, customVocabulary:)`. Update the `XPCTranscriberAdapter`-style adapter in `AppCore+Live.swift` (~line 228) to pass through.
- `resolveAudioPaths` returns `(mic: URL?, system: URL?)?`. The "No audio files available for this meeting." failure fires only when the store returns nil.
- The in-flight guard stays as a safety net. The queue (§4) makes it unreachable in normal flows.
- `FakeTranscriber` records `lastMic: URL?` and `lastSystem: URL?`.
- Test: `TranscriptionServiceTests.transcribe_singleTrackMeeting_passesNilMic`.

---

## 4. Post-processing queue (`AppCore/PostProcessingQueue.swift`)

### 4.1 Type

```swift
/// App-wide serial FIFO of heavy post-recording work. Each entry runs the
/// injected runner to completion (transcribe -> AI auto-enhancements) before
/// the next starts. Main-actor; the runner's awaits hop to the services.
@MainActor @Observable
public final class PostProcessingQueue {
    public enum Kind: Sendable, Equatable { case transcribe, reTranscribe }

    public struct Entry: Sendable, Equatable {
        public let meetingID: UUID
        public let kind: Kind
    }

    /// Entries not yet started, in run order.
    public private(set) var waiting: [Entry] = []
    /// The entry currently running, if any.
    public private(set) var running: Entry?

    public init(runner: @escaping @MainActor (Entry) async -> Void)

    /// Appends unless the meeting is already waiting or running (no-op then).
    public func enqueue(_ meetingID: UUID, kind: Kind)
    /// Drops a WAITING entry for the meeting (no effect on a running one).
    public func remove(_ meetingID: UUID)
    /// True when the meeting has a waiting (not yet running) entry.
    public func isWaiting(_ meetingID: UUID) -> Bool
    /// True when the meeting is waiting or running.
    public func isActive(_ meetingID: UUID) -> Bool
    /// Test seam: returns once the queue is empty and idle.
    package func awaitIdle() async
}
```

### 4.2 Algorithm

- `enqueue` appends, then calls `startIfNeeded()`.
- `startIfNeeded()`: if `worker == nil`, set `worker = Task { @MainActor in … }`, which loops:
  1. While `!waiting.isEmpty`: `let entry = waiting.removeFirst()`, then `running = entry`, `await runner(entry)`, `running = nil`.
  2. Then `worker = nil`.
- The runner never throws. A failure inside it is recorded by the services' own job status, and the loop continues.
- `awaitIdle()`: `while let worker { await worker.value }`. Re-check after each await, since new work may have started.

### 4.3 Runner (in AppCore)

```swift
private func runPostProcessing(_ entry: PostProcessingQueue.Entry) async {
    switch entry.kind {
    case .transcribe:   await transcription.transcribe(meetingID: entry.meetingID)
    case .reTranscribe: await transcription.reTranscribe(meetingID: entry.meetingID)
    }
    await intelligence.runAutoEnhancements(meetingID: entry.meetingID)
}
```

This is exactly today's `stopRecording` task body and today's `MeetingDetailViewModel.reTranscribe()` sequence. `runAutoEnhancements` no-ops when there's no transcript (failed transcription), as today. Its existing "busy → skip" guard is left alone (functional spec §10).

### 4.4 AppCore integration

- `public let postProcessing: PostProcessingQueue`. Built in `init`, with `runner: { [unowned self] in await self.runPostProcessing($0) }`. Init order: build the queue after the other stored properties. If Swift's init rules require it, make it `lazy` or use an optional-then-set pattern. The coding agent picks whichever compiles cleanly under `@Observable`.
- **`stopRecording`**: replace the `pendingTranscriptionTask = Task { … }` block with `postProcessing.enqueue(meetingID, kind: .transcribe)`. Delete `pendingTranscriptionTask`.
- **`awaitPendingTranscription()`** (the existing test seam): reimplemented as `await postProcessing.awaitIdle()`. Existing tests keep compiling.
- **New public API** (used by MeetingDetailUI):
  ```swift
  public func enqueueTranscription(meetingID: UUID)    // Retry
  public func enqueueReTranscription(meetingID: UUID)  // Re-transcribe / Transcribe now
  ```
- **Delete**: `deleteSingleMeetingInternal` calls `postProcessing.remove(meetingID)` first. A running entry is left alone. Today's behavior covers it: the transcription fails with "Meeting not found." and the AI step no-ops.

### 4.5 Tests (`AppCoreTests/PostProcessingQueueTests`)

- `enqueue_runsInFIFOOrder`: a recording runner appends ids; three enqueues produce [a, b, c].
- `enqueue_duplicateWhileWaiting_isNoOp` and `enqueue_duplicateWhileRunning_isNoOp`.
- `remove_dropsWaitingEntry_notRunning`.
- `isWaiting_trueOnlyBeforeStart`: uses a runner gated on a continuation.
- `runnerFailure_doesNotStopQueue`: a runner whose first call's transcription fails; the second still runs.
- `stopRecording_enqueuesTranscribe`: a `CoreFixture` record → stop, then the queue runs and `FakeTranscriber` is called.
- `twoMeetings_bothTranscribe_noAlreadyInProgressFailure`: the regression for the old single-in-flight rejection. Enqueue two meetings back-to-back; both reach `.completed`.

---

## 5. AppCore: import wiring

### 5.1 Route

`Route.importing` (new case; doc: "The Import screen (session-long import list)."). Exhaustive `switch`es over `Route` (DetailContentView, menu bar, link handling) get a case. Non-UI switches treat it like `.home`/`.settings` (no special behavior).

### 5.2 Ownership and API

```swift
public let audioImport: AudioImportController   // built in init / live()

/// Adds files to the session and shows the Import screen. No-op during
/// onboarding (route == .onboarding).
public func importFiles(_ entries: [ImportEntry])

/// Sidebar "Imported" row.
public func showImport()                       // route = .importing

/// File > Import Audio File... request. The App sets it; AppShellView
/// consumes it by presenting `.fileImporter` (see import_ui.md).
public private(set) var importPanelRequested = false
public func requestImportPanel()               // guard route != .onboarding; set true
public func consumeImportPanelRequest()        // set false
```

- `importFiles`:
  1. `guard route != .onboarding, !entries.isEmpty`.
  2. `let batchSize = entries.count`, then `audioImport.add(entries)`, then `route = .importing`.
  - It doesn't touch `meetingsSelection` or search.
- `AppCore.live(...)` builds `AudioImportController(store: store, recordingsRoot: recordingsRoot)`. The test `init` takes an optional `audioImport: AudioImportController? = nil`. The default builds one over the same store with a temp recordings root. `CoreFixture` injects one with a fake converter.

### 5.3 Completion → queue + navigation

`AudioImportController.onItemFinished` (see the component doc) is set by AppCore in `init`:

```swift
audioImport.onItemFinished = { [weak self] finished in
    guard let self else { return }
    guard case let .done(meetingID) = finished.item.status else { return }
    await reloadSummaries()
    postProcessing.enqueue(meetingID, kind: .transcribe)
    if ImportAutoNavigation.shouldNavigate(
        batchSize: finished.batchSize,
        controllerHasPendingWork: audioImport.hasPendingWork,
        route: route
    ) {
        select(meetingID)
    }
}
```

`ImportAutoNavigation` lives in `AppCore` as a pure `enum` (it needs `Route`):

```swift
enum ImportAutoNavigation {
    static func shouldNavigate(batchSize: Int, controllerHasPendingWork: Bool, route: Route) -> Bool {
        batchSize == 1 && !controllerHasPendingWork && route == .importing
    }
}
```

`hasPendingWork` = any item still `.receiving`, `.waiting` or `.converting`. When the callback fires, the finished item is already `.done`.

### 5.4 Launch

In `onLaunch`, next to `recording.recoverOrphans()`: `AudioImportController.cleanStaging(recordingsRoot:)`, which removes `Recordings/.import-staging/` (left by a crash mid-conversion). The live wiring passes `recordingsRoot` in. The method is `nonisolated static`, so it's callable before any session exists.

### 5.5 Tests (`AppCoreTests/AppCoreImportTests`)

All use `CoreFixture` + `FakeAudioConverter`:
- `importFiles_routesToImporting_andAppends`.
- `importFiles_duringOnboarding_isNoOp`.
- `importDone_enqueuesTranscription_andReloadsSummaries`.
- `singleFile_onImportScreen_autoNavigatesToMeeting`.
- `singleFile_userNavigatedAway_doesNotNavigate`.
- `multiFile_neverAutoNavigates`.
- `singleFileAppendedWhileOthersPending_doesNotNavigate`.
- `deleteQueuedImportedMeeting_removesWaitingEntry`.
- `requestImportPanel_setsFlag_consumeClears_onboardingGuard`.
- `ImportAutoNavigationTests`: the truth table of the pure predicate.

---

## 6. Meeting detail (`MeetingDetailUI`)

- `reTranscribe()` → `core.enqueueReTranscription(meetingID: meetingID)`. It no longer awaits or calls `load()` or `runAutoEnhancements`. The view already reloads on `currentJobStatus` and `enhancementStatus` changes (`MeetingDetailView.swift` ~line 78/84). Callers (`Transcribe now`, the menu item, `reTranscribeAfterCorrection`) keep their `Task { await … }` wrappers. The method stays `async` to avoid call-site churn; mark it `// TODO` only if lint flags an unused `async`. Otherwise make it sync and update the call sites.
- `retry()` → `core.enqueueTranscription(meetingID: meetingID)`.
- New derived `isQueued: Bool { core.postProcessing.isWaiting(meetingID) }`.
- `displayState`: evaluate in this order:
  1. `.downloadingModel` / `.transcribing` → today's processing states.
  2. **`isQueued` → `.processing(message: "Waiting to transcribe…")`**.
  3. `.failed` → today's failed state.
  4. Everything else → as today.
- `canReTranscribe`: also `false` when `core.postProcessing.isActive(meetingID)`.
- `pipelineStages`:
  - Treat `isQueued` as pipeline-visible (add it to the `guard`).
  - When queued, stage 1 is `PipelineStage(label: "Waiting to transcribe", state: .pending)`, and gated later stages are `.pending`.
  - Otherwise, today's logic.
- Tests (`MeetingDetailUITests`):
  - `displayState_queued_showsWaitingToTranscribe`.
  - `displayState_queuedAfterFailure_prefersWaiting`.
  - `canReTranscribe_falseWhileQueued`.
  - `pipelineStages_queued_firstStageWaiting`.
  - `retry_enqueuesTranscribeKind`.
  - `reTranscribe_enqueuesReTranscribeKind`.

  Drive the queue state with a runner gated on a continuation, or by enqueueing behind a blocked entry.

---

## 7. Error handling and logging

- `AudioImport` maps every failure to the closed `ImportFailure` enum (component doc §4). User-facing strings live on that enum (`message`) and are unit-tested.
- Every failure is logged with `Logger(subsystem: "net.scosman.biscotti", category: "AudioImport")`:
  - the underlying `Error` / `OSStatus` at `.error`;
  - the file name `privacy: .private` and the extension `.public`.
  - Never log full paths as public.
- Conversion errors never propagate past the controller. The item becomes `.failed` and the worker continues.
- The queue runner can't fail. The services surface their own `.failed` job states, as today.
- Cleanup on failure: delete the staging file, any partially created meeting directory, and the promised temp file. A meeting is inserted only in the final step, in a single save.

---

## 8. Concurrency

- `AudioImportController`, `PostProcessingQueue`, `AppCore` and all view models are `@MainActor`.
- The heavy conversion runs in `Task.detached(priority: .userInitiated)` inside the live converter (the pattern `AppCore+ImportExport` and `CalendarService` already use). The main actor only awaits its result. The decode → encode loop checks `Task.isCancelled` per sample buffer. Nothing cancels it today, but it's cheap and future-proof.
- The media-date read is a separate detached task per item, started at add time so rows show dates immediately.
- Conversion (one at a time) overlaps with the post-processing queue (one at a time). That's intentional: transcription of file 1 runs while file 2 converts. Peak cost is one AVAssetReader decode plus one transcription job, well within normal recording-plus-transcription memory.

---

## 9. Testing strategy

All automated tests run under `make test` (`swift test`, no signing, no hardware). Real-file conversion tests use AVFoundation directly, which works in `swift test` on macOS CI.

| Target | What |
|---|---|
| `TranscriptionTests` (pkg) | §3.3 |
| `DataStoreTests` | `createImportedMeeting_persistsAllFields_inOneSave`. `audioPaths_singleTrack_returnsSystemOnly`. `audioPaths_noPresentRefs_returnsNil`. The title policy truth table. `applyGeneratedTitle_replacesPlaceholder_andClearsFlag`. `applyGeneratedTitle_keepsCustomNonPlaceholderTitle`. `setTitle_clearsPlaceholder`. `applyEventTitle_replacesPlaceholder_andClearsFlag`. `meetingDetail_exposesTitleIsPlaceholder`. |
| `IntelligenceTests` | `autoRun_placeholderTitle_getsAITitle`. `autoRun_afterAITitle_doesNotRetitle`. `autoRun_editedTitle_untouched`. Uses the existing fake LLM runner. |
| `TranscriptionServiceTests` | §3.4 |
| `AudioImportTests` | Component doc §6 (classifier, real-file converter, metadata, controller, header copy). |
| `AppCoreTests` | §4.5, §5.5 |
| `MeetingDetailUITests` | §6 |
| `ImportUITests` | `components/import_ui.md` §7 (pasteboard classification → overlay state, overlay copy, view-model row mapping). |
| `AppShellUITests` | `importedRow_hiddenUntilFirstImport_thenPersists`. `importedRow_selectedOnImportingRoute`. |
| `DesignSystemTests` | Existing token tests extended to the new tokens, if a token-table test exists. |

### 9.1 Manual verification (human, on a Mac)

The drop target can't be unit-tested. The phase that builds it (implementation plan, Phase 5) ends with a human checklist (`components/import_ui.md` §6). This project doesn't add a ManualTestApp script: ManualTestApp is for library-level hardware behavior, and this is app-shell UI. The coding agent provides the checklist in the phase plan, and the human runs it before that phase's commit.

---

## 10. Risks

| Risk | Mitigation |
|---|---|
| **The AppKit drop view can't be both click-through and window-wide** (hit-testing interactions with SwiftUI's `NSHostingView`, the toolbar strip in the titlebar container). | Spike first in Phase 5. Placement candidates are ordered, with acceptance criteria (`components/import_ui.md` §2.4). The worst-case fallback is a SwiftUI `.onDrop` with a coarser hover state. The toolbar strip is best-effort (final question to the product owner). |
| AVAssetReader downmix for >2-channel sources | Pass an explicit mono `AVChannelLayoutKey` in the reader output settings. Test a 6-channel WAV in `AudioImportTests`. |
| Some `public.audio` types AVFoundation can't decode (e.g. Ogg Vorbis) | They pass the hover check and fail at conversion with the generic message (functional spec §3). This is accepted. |
| File-promise sources vary (Photos exports can be slow) | Rows show "Receiving…". The worker awaits delivery in order. A delivery error makes the row fail. |
| Transcription package change ripples to the XPC service | JSON payload with optional fields, and the service ships in the same bundle. Covered by codec tests, and the `tx_*` manual tests reset for a hardware re-run. |
