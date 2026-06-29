---
status: complete
---

# Architecture: Model Download UX

Single-doc architecture (the change set is medium and spans no component complex
enough to warrant its own design doc). Three features — LLM cancel, transcription
cancel, click-time disk check — each cut across a download engine, an app-level
manager, and one or two SwiftUI surfaces.

## 0. Affected modules & flow

```
LLM:            ModelDownloader (LocalLLM)  ◄─ download/cancel ── ModelManager (Intelligence)
                                                                      ▲ start/cancel/diskWarning
                                          ManageModelsViewModel ──────┤ (Settings)
                                          OnboardingViewModel ────────┘ (language row)

Transcription:  WhisperKit/SpeakerKit  ◄─ runs in XPC worker ─ InProcessTranscriptionEngine
                          ▲ killed by connection invalidation
                  Transcriber (.hosted) ◄── cancelModelDownload ── TranscriptionService
                                                                      ▲ cancel/estimate
                                          OnboardingViewModel ────────┘ (transcription row)

Shared disk policy: DiskWarning + buffer + formatting live in Intelligence,
reused by both surfaces.
```

Real app backend is `.hosted` (`AppCore+Live.swift:55`), so transcription downloads
run **in the `BiscottiTranscriber.xpc` worker process**. This is the key fact
behind the transcription-cancel design (§3).

---

## 1. Disk-space pre-check (shared)

### 1.1 Shared value + policy (new, in `Intelligence`)

`Intelligence` is imported by every download surface (`ModelManagementUI`,
`OnboardingUI`, `SettingsUI`), so the shared disk policy lives there.

```swift
// Intelligence/DiskWarning.swift  (new)
public struct DiskWarning: Equatable, Sendable {
    public let modelName: String
    public let requiredBytes: Int64    // download size + buffer
    public let availableBytes: Int64
}

public enum ModelDiskPolicy {
    /// Generous round buffer beyond the raw download size (functional spec §5.2).
    public static let downloadBufferBytes: Int64 = 2_000_000_000  // 2 GB

    /// Returns a `DiskWarning` when free space is insufficient, else nil.
    /// `freeBytes == nil` (capacity read failed) ⇒ nil (never falsely block).
    public static func warning(
        modelName: String,
        downloadBytes: Int64,
        freeBytes: Int64?
    ) -> DiskWarning? {
        guard let freeBytes else { return nil }
        let required = downloadBytes + downloadBufferBytes
        guard freeBytes < required else { return nil }
        return DiskWarning(
            modelName: modelName, requiredBytes: required, availableBytes: freeBytes
        )
    }

    /// "~N GB" / "~N.N GB" formatting for alert copy (moved from
    /// OnboardingViewModel.formatBytes so both surfaces share it).
    public static func formatBytes(_ bytes: Int64) -> String { … }
}
```

`ModelSuitability.hasEnoughDisk` and the `ModelChoice.hasEnoughDiskToDownload` /
`ModelBlockedReason.insufficientDisk` machinery are **removed** (§4) — the
click-time `ModelDiskPolicy.warning` replaces them.

### 1.2 LLM path (`ModelManager`)

```swift
// ModelManager
public func downloadDiskWarning(id: String) -> DiskWarning? {
    guard let model = models.catalog.first(where: { $0.id == id }) else { return nil }
    let free = models.url(for: id).flatMap { hardware.availableDiskBytes(at: $0) }
    return ModelDiskPolicy.warning(
        modelName: model.displayName,
        downloadBytes: model.approxDownloadBytes,
        freeBytes: free
    )
}
```

### 1.3 Transcription path

Expose the engine's currently-private size estimate so the app can compute the
requirement (replacing onboarding's hardcoded 1500 MB):

```swift
// Transcription package — promote the private `estimatedDownloadBytes`
public enum TranscriptionDownloadSize {
    public static func estimatedBytes(method: TranscriptionMethod = .current) -> Int64
    // body = the existing size table keyed off MethodResolver.resolve(method).sttModel
}

// TranscriptionService
public var estimatedModelDownloadBytes: Int64 {
    TranscriptionDownloadSize.estimatedBytes()
}
```

`OnboardingViewModel` builds the transcription `DiskWarning` from
`core.transcription.estimatedModelDownloadBytes` and its already-injected
`availableDiskBytes()` closure (volume-wide capacity at the home dir, same volume as
the model cache).

### 1.4 Where the check runs

The check is performed **at Download tap**, inside each surface's download action,
*before* kicking off the download. If a `DiskWarning` is returned, the surface sets
its `diskWarning` state (drives a `.alert`) and returns without starting. There is
no proactive/persistent disk state and no Re-check button — a later tap re-runs the
same check (functional spec §5.1, §5.3).

The transcription engine's existing internal `DiskSpaceChecker` throw
(`InProcessTranscriptionEngine.checkDiskSpace`) stays as a defensive backstop.

---

## 2. LLM cancel

### 2.1 Task retention in `ModelManager` (Intelligence)

Today `downloadModel(id:)` is awaited from a fire-and-forget `Task {}` in the VMs, so
nothing is cancellable. `ModelManager` becomes the task owner:

```swift
// ModelManager — new state
private var downloadTasks: [String: Task<Void, Never>] = [:]

/// Start (retained, cancellable). Replaces VM-side `Task { downloadModel(id:) }`.
public func startDownload(id: String) {
    guard downloadTasks[id] == nil else { return }   // already downloading this id
    guard canStartDownload(id: id) else { return }   // RAM + one-at-a-time (unchanged)
    let task = Task { [weak self] in
        await self?.runDownload(id: id)
    }
    downloadTasks[id] = task
}

/// Cancel an in-flight download. Cooperative cancellation propagates through
/// `models.download` → `ModelDownloader` (URLSession task.cancel()), which deletes
/// the `.partial` file. The CancellationError path (below) sets `.notDownloaded`.
public func cancelDownload(id: String) {
    downloadTasks[id]?.cancel()
}
```

`runDownload(id:)` is the former `downloadModel(id:)` body, with two changes:

- `defer { downloadTasks[id] = nil }` so the task entry is always cleared (success,
  failure, cancel) — re-enabling a subsequent download (and the one-at-a-time guard).
- Its existing `catch is CancellationError { downloads[id] = .notDownloaded }` branch
  now actually fires for user cancels — see §2.2.

(The async `runDownload`/`downloadModel` core stays callable directly by unit tests.)

### 2.2 Cancellation must read as cancel, not failure (`ModelDownloader`, LocalLLM)

**Bug today:** a cancelled `URLSessionDataTask` surfaces `NSURLErrorCancelled`, which
`ModelDownloader.download`'s `catch` wraps into `LocalLLMError.downloadFailed`. That
would hit `ModelManager`'s generic `catch` → `.failed`, not `.notDownloaded`.

Fix in `ModelDownloader.download`'s `catch` block — keep the temp-file delete, then
classify:

```swift
} catch {
    try? FileManager.default.removeItem(at: tempPath)   // delete .partial (unchanged)
    if error is CancellationError { throw CancellationError() }
    let ns = error as NSError
    if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled {
        throw CancellationError()
    }
    if let llmError = error as? LocalLLMError { throw llmError }
    throw LocalLLMError.downloadFailed(url: source, underlying: error.localizedDescription)
}
```

Result: user cancel → `CancellationError` → `ModelManager` sets `.notDownloaded`,
partial file removed. Genuine failures keep the `.failed` + Retry path.

### 2.3 Edge cases

- **Cancel vs. completion race:** the URLSession delegate's `finished`/lock guard
  already makes the continuation resume exactly once; whichever of completion/cancel
  the delegate observes first wins. No half state.
- **One-at-a-time:** `downloadTasks[id]=nil` in the `defer` plus the existing
  `canStartDownload` in-flight guard means a fresh download is startable once a
  cancel settles.

---

## 3. Transcription cancel (best-effort, hosted-backend-aware)

### 3.1 Mechanism — invalidate the XPC connection (reliable), not Task cancellation

For `.hosted`, the download runs in the worker process. Cancelling the app-side Swift
Task only abandons the *await* of the XPC reply; the worker keeps downloading. The
reliable stop is **tearing down the connection** — `Transcriber.shutdown()` invalidates
the `NSXPCConnection`, launchd terminates the idle worker, and the worker's in-flight
URLSession download dies with the process. Then we delete any partial files from the
shared cache directory. This is *more* reliable than hoping `swift-transformers`
honors Task cancellation, and it's why best-effort cancel is sound for the real app.

For `.inProcess` (CLI/tests only), there is no worker to kill; we rely on Task
cancellation propagating into the SDK (best-effort) and then delete the cache dir.

### 3.2 New API

```swift
// Transcriber (Transcription)
/// Stop an in-flight model download and remove partial files.
/// Hosted: invalidate the connection (kills the worker + its download), then
/// clear the model cache. InProcess: just clear the cache (caller cancels the Task).
public func cancelModelDownload() async {
    shutdown()                       // hosted: invalidate; inProcess: no-op
    try? ModelStorage.clearCache()   // rm the models/ tree (idempotent, scoped)
    emitStatus(.needsDownload)
}

// TranscriptionService
public func cancelModelDownload() async {
    await engineTranscriber.cancelModelDownload()
}
```

Note: `TranscriptionService` currently holds the engine behind the `Transcribing`
seam (a fake in tests). `cancelModelDownload()` is added to `Transcribing` so the
service can forward it; the live impl forwards to `Transcriber`, the fake records the
call. `ModelStorage.clearCache()` already exists and only removes `models/`.

### 3.3 Onboarding wiring & state

`startTranscriptionDownload()` becomes synchronous and retains its task so it can be
cancelled:

```swift
// OnboardingViewModel — new state
private var transcriptionDownloadTask: Task<Void, Never>?
private var transcriptionCancelled = false
public var diskWarning: DiskWarning?           // drives the alert (shared)

public func startTranscriptionDownload() {
    if let w = transcriptionDiskWarning() { diskWarning = w; return }   // §1.3 check
    guard transcriptionDownloadTask == nil else { return }
    transcriptionCancelled = false
    isDownloading = true; downloadFailed = false; downloadStatus = "Preparing…"
    transcriptionDownloadTask = Task { [weak self] in
        await self?.runTranscriptionDownload()
        self?.transcriptionDownloadTask = nil
    }
}

public func cancelTranscriptionDownload() {
    guard isDownloading else { return }
    transcriptionCancelled = true
    transcriptionDownloadTask?.cancel()
    Task { [weak self] in
        await self?.core.transcription.cancelModelDownload()   // kill worker + clear files
        guard let self else { return }
        isDownloading = false; downloadStatus = nil
        downloadComplete = false; downloadFailed = false
    }
}
```

`runTranscriptionDownload()` is the former `startTranscriptionDownload` body; its
`catch` is guarded so a cancel doesn't show a failure:
`catch { if !transcriptionCancelled { downloadFailed = true; downloadStatus = "Download failed. You can retry or skip." } }`,
and its success path sets `downloadComplete` only when `!transcriptionCancelled`. The
`transcriptionCancelled` flag (set before `.cancel()`) wins the race against the
task's own catch.

### 3.4 Risks / verification

- **Delete-while-writing window:** between `shutdown()` and the worker's actual
  SIGKILL there's a sub-second window where the worker could re-create files after
  `clearCache()`. Accepted as best-effort (functional spec §4.3). If stragglers
  remain, the next `modelsArePresent()` either reports incomplete (→ re-download) or,
  worst case, a stale partial is cleared by the user re-running the download.
- **Hardware verification required** (functional spec §4.3): manual test confirms
  cancel returns promptly, no leftover partial model files, re-download succeeds.
  Touching `Packages/Transcription` ⇒ mark `tx_*` manual tests `not-run`
  (repo manual-test staleness rule).

---

## 4. Removal of proactive disk states

Replaced by the click-time alert (functional spec §5.3). RAM `cannotRun` blocking is
untouched.

- `Intelligence/EnhancementStatus` (`ModelChoice`): remove `hasEnoughDiskToDownload`;
  `ModelBlockedReason` loses `.insufficientDisk` (keeps `.cannotRun`); `blockedReason`
  computes from RAM only.
- `ModelManager.modelChoices()`: drop the `freeBytes` read + `hasEnoughDisk` call.
- `ModelManagementUI/ManageModelsSheet` (`ModelRowView.primaryAction`): Download
  button no longer `.disabled` on insufficient disk; `.downloading` action becomes the
  **Cancel** button (below progress, per ui_design). `warningLabel(for: .insufficientDisk)`
  paths removed.
- `OnboardingUI/ModelRowState`: remove `.insufficientDisk`; remove
  `transcriptionInsufficientDisk`, the `languageRowState` disk-block branch, and the
  `DownloadControl.insufficientDisk`/`diskWarning` view.
- `OnboardingViewModel`: remove `hasSufficientDisk`, `requiredDiskSpaceMB`,
  `checkDiskSpace()`, and its call in `runModelProbes()`. (`availableDiskBytes`
  closure is kept — now used by the click-time `transcriptionDiskWarning()`.)

---

## 5. UI wiring (per ui_design.md)

- **Cancel control** — small bordered "Cancel" button, placed **below** the progress:
  - `ManageModelsSheet.ModelRowView`: in `descriptionOrProgress`'s `.downloading`
    case, render Cancel under the `ProgressView`, calling `onCancel`. New `onCancel`
    closure on `ModelRowView` → `ManageModelsViewModel.cancel(id:)` →
    `core.modelManager.cancelDownload(id:)`. Trailing `primaryAction` stays empty
    while downloading.
  - `OnboardingUI/DownloadControl`: add an `onCancel` closure; in `downloadingContent`
    render Cancel beneath the bar/spinner. Language row → `cancelLanguageDownload()`
    (→ `core.modelManager.cancelDownload(id:)` for the in-flight id); transcription
    row → `cancelTranscriptionDownload()`. `ModelDownloadRow`/`ModelCard` thread the
    two cancel closures through.
- **Disk alert** — `.alert` bound to each VM's `diskWarning: DiskWarning?`:
  - Title `Not Enough Disk Space`; message
    `“\(modelName)” needs about \(format(required)) of free space to download, but only \(format(available)) is free. Free up some space and try again.`;
    one `OK` button that clears `diskWarning`.
  - Settings: presented from `ManageModelsSheet`. Onboarding: presented from the
    model-download step. `ManageModelsViewModel` gains `var diskWarning: DiskWarning?`,
    set in its `download(id:)` action.
- **Onboarding footer**: unchanged logic; "started" derivation already keys off live
  download state, so a cancel naturally reverts Continue→Skip (ui_design §4).

### 5.1 LLM download actions (both surfaces) — final shape

```swift
// ManageModelsViewModel.download(id:)
if let w = core.modelManager.downloadDiskWarning(id: id) { diskWarning = w; return }
core.modelManager.startDownload(id: id)

// OnboardingViewModel.startLanguageDownload()
guard let id = languageTargetModelID else { return }
if let w = core.modelManager.downloadDiskWarning(id: id) { diskWarning = w; return }
core.modelManager.startDownload(id: id)
```

---

## 6. Public interface changes (summary)

| Type | Change |
|---|---|
| `ModelManager` | + `startDownload(id:)`, `cancelDownload(id:)`, `downloadDiskWarning(id:)`; `downloadModel`→`runDownload` core + task retention |
| `ModelDownloader` (LocalLLM) | `catch` maps `NSURLErrorCancelled`/`CancellationError` → `CancellationError` (still deletes `.partial`) |
| `Intelligence` | + `DiskWarning`, `ModelDiskPolicy` (buffer, `warning(...)`, `formatBytes`) |
| `ModelChoice`/`ModelBlockedReason` | − `hasEnoughDiskToDownload`, − `.insufficientDisk` |
| `ModelSuitability` | − `hasEnoughDisk` (superseded by `ModelDiskPolicy`) |
| `Transcriber` | + `cancelModelDownload()` |
| `Transcribing` (seam) + `TranscriptionService` | + `cancelModelDownload()`; `TranscriptionService` + `estimatedModelDownloadBytes` |
| `Transcription` | + `TranscriptionDownloadSize.estimatedBytes(method:)` (promotes private estimate) |
| `OnboardingViewModel` | `startTranscriptionDownload()`→sync+retained; + `cancelTranscriptionDownload()`, `cancelLanguageDownload()`, `diskWarning`; − `hasSufficientDisk`/`checkDiskSpace()`/`requiredDiskSpaceMB` |
| `ManageModelsViewModel` | + `cancel(id:)`, `diskWarning`; `download(id:)` does click-time check |
| UI rows | + Cancel control (below progress); − inline insufficient-disk views |

---

## 7. Error handling

| Situation | Outcome |
|---|---|
| LLM user cancel | `CancellationError` → `.notDownloaded`; `.partial` deleted; no error UI |
| Transcription user cancel | worker killed (hosted) / Task cancelled (inproc) → cache cleared → row idle; `transcriptionCancelled` suppresses the failure branch |
| Insufficient disk at tap | `DiskWarning` alert (OK only); download never starts; no `.failed` recorded |
| Genuine download failure | existing `.failed(message:)` + Retry (LLM) / `downloadFailed` text + Retry (transcription), unchanged |

---

## 8. Testing strategy

**Unit (gating, `swift test`):**
- `ModelDiskPolicy.warning`: below/at/above threshold (incl. the +2 GB buffer
  boundary), `nil` freeBytes ⇒ nil. `formatBytes` cases.
- `ModelDownloader`: a cancelled task throws `CancellationError` (not
  `downloadFailed`) and leaves no `.partial`. Use a controllable URLProtocol / slow
  stream so the test can cancel mid-flight; assert temp file absent after.
- `ModelManager`: `startDownload` retains a task; `cancelDownload` → `.notDownloaded`
  and clears the task entry; one-at-a-time still holds; `downloadDiskWarning` returns
  a warning when the injected `HardwareProbing.availableDiskBytes` is low and nil when
  ample. (Inject a fake `ModelProviding` whose `download` blocks until cancelled.)
- `OnboardingViewModel`: `startTranscriptionDownload` with a low injected disk closure
  sets `diskWarning` and does not start; `cancelTranscriptionDownload` calls the fake
  `Transcribing.cancelModelDownload`, resets flags, and (via `transcriptionCancelled`)
  does not set `downloadFailed`. Language cancel calls `ModelManager.cancelDownload`.
- `ManageModelsViewModel`: `download(id:)` with low disk sets `diskWarning` + no start;
  `cancel(id:)` forwards to `ModelManager`.
- `TranscriptionService`: `cancelModelDownload` forwards to the engine seam;
  `estimatedModelDownloadBytes` returns the promoted estimate.
- `TranscriptionDownloadSize.estimatedBytes` table per model variant.

**Manual (on-hardware, non-gating gate):** the §3.4 transcription-cancel checks; LLM
cancel mid-download leaves no `.gguf.partial`; disk-warning alert copy. Mark `tx_*`
(and re-verify `llm_*`) `not-run` per the staleness rule when their packages change.

**Not added:** download-resume tests (out of scope); cross-download disk accounting
(intentionally absent — buffer covers it, §1).

---

## 9. Sequencing notes for implementation

- The two cancels are independent code paths and can land in either order; the disk
  check touches both surfaces and shares `ModelDiskPolicy`, so land the shared policy
  first.
- `ModelSuitability.hasEnoughDisk` removal must be done together with the
  `ModelChoice`/`modelChoices`/`ModelRowView` edits (they reference it), to keep the
  build green.
