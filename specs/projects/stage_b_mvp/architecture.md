---
status: complete
---

# Architecture: Stage B — MVP (Record → Transcribe)

Technical design for the MVP, deep enough to code from. The **static topology** (component homes,
boundaries, dependency edges) is already fixed by the repo
[`architecture.md`](../../../architecture.md); this doc designs the **concrete app-level APIs** for
the first slices of those components, the threading model, storage, orphan recovery, and the
package/Xcode wiring. Foundation-engine APIs are fixed and only **consumed** here.

> Manual-test staleness note: this project **only consumes** `AudioCapture` and `Transcription` (no
> edits to those packages), so the `ac_*`/`tx_*` manual-test staleness rule is **not** triggered. We
> *do* extend the `DataStore` module (additive read-model DTOs) — DataStore has no manual tests, so
> that's safe.

---

## 1. Module map (new targets in `BiscottiKit`)

All new app-level code is **modules (targets) in `Packages/BiscottiKit`** — keeping the app target
thin (per repo topology). New targets:

| Target | Layer | Depends on (internal) | Depends on (external) |
|---|---|---|---|
| `DesignSystem` | L0 | — | SwiftUI |
| `Permissions` | L0 | — | AVFoundation, AppKit (settings URLs) |
| `Recording` | L1 | `DataStore`, `Permissions` | `AudioCapture` (pkg) |
| `TranscriptionService` | L1 | `DataStore` | `Transcription` (pkg) |
| `AppCore` | L2 | `Recording`, `TranscriptionService`, `Permissions`, `DataStore` | — |
| `MeetingListUI` | L3a | `AppCore`, `DataStore`, `DesignSystem` | SwiftUI |
| `RecordingUI` | L3a | `AppCore`, `DesignSystem` | SwiftUI |
| `MeetingDetailUI` | L3a | `AppCore`, `DataStore`, `TranscriptionService`, `DesignSystem` | SwiftUI |
| `AppShellUI` | L3b | `AppCore`, `MeetingListUI`, `RecordingUI`, `MeetingDetailUI`, `DesignSystem` | SwiftUI |

`DataStore` gets additive read-model DTOs (below). The app target consumes three library products:
`AppShellUI`, `AppCore`, `DataStore`.

**Out of the MVP** (later projects): `MenuBarUI`, `HomeUI`, `SearchUI`, `SettingsUI`,
`OnboardingUI`, `Calendar`, `MeetingDetection`, `Notifications`, `Vocabulary`, `RemoteConfig`.

---

## 2. Threading model (the rule)

- **Background actors do the heavy work** and already exist: `AudioCapture.AudioRecorder` (actor),
  `Transcription.Transcriber` (actor), `DataStore` (actor). Nothing in the MVP blocks the main thread
  on capture, ML, or persistence.
- **App services + view models are `@MainActor @Observable` classes** that hold UI-facing state and
  `await` the background actors. They pump the engines' `AsyncStream`s (`stateStream`, `statusStream`)
  into `@Observable` properties via `Task`s, so SwiftUI binds without actor hops.
- **No live `@Model` objects cross to the UI.** `DataStore` returns **`Sendable` DTOs** (mapped from
  `@Model` *inside* the actor). View models hold DTOs only — clean strict-concurrency, easy tests.

---

## 3. `DataStore` additive read-model DTOs

New `Sendable` value types + actor query methods (map `@Model` → DTO on the actor):

```swift
public struct MeetingSummary: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let title: String
    public let date: Date          // startDate ?? createdAt
    public let hasTranscript: Bool
}

public struct MeetingDetailData: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let title: String
    public let date: Date
    public let duration: TimeInterval?     // derived from audio if known
    public let hasAudio: Bool
    public let preferredTranscript: TranscriptData?
}

public struct TranscriptData: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let createdAt: Date
    public let speakerCount: Int
    public let segments: [SegmentData]     // ordered by index
}

public struct SegmentData: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let speakerLabel: String
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let text: String
}

extension DataStore {
    public func meetingSummaries(limit: Int) throws -> [MeetingSummary]
    public func meetingDetail(id: UUID) throws -> MeetingDetailData?
    public func audioPaths(meetingID: UUID) throws -> (mic: URL, system: URL)?   // for transcribe
}
```

These are the **only** DataStore changes. Existing methods (`createMeeting`, `attachAudio`,
`addTranscript`, `setPreferredTranscript`, `markAudioPresence`, `recentMeetings`, `meeting(id:)`) are
reused as-is.

---

## 4. `Permissions` module (mic-focused; system-audio inferred by Recording)

Permissions stays internal-dep-free (per topology). It fully owns **microphone** (public TCC API)
and the **settings-recovery** surface. **System audio has no public status API**, so its prompt is
*triggered* and its denial *inferred* by the `Recording` flow (which owns `AudioCapture`); Permissions
just stores the inferred result for the UI.

```swift
public enum PermissionState: Sendable, Equatable { case notDetermined, authorized, denied }

public enum PermissionKind: Sendable { case microphone, systemAudio }

public protocol MicAuthorizing: Sendable {            // seam over AVCaptureDevice
    func status() -> PermissionState
    func request() async -> Bool
}

@MainActor @Observable
public final class Permissions {
    public private(set) var microphone: PermissionState
    public private(set) var systemAudio: PermissionState     // set by Recording's inference
    public init(mic: any MicAuthorizing = LiveMicAuthorizer())
    public func refresh()                                    // re-read mic on app focus
    public func requestMicrophone() async -> Bool
    public func noteSystemAudio(_ state: PermissionState)    // Recording reports inference here
    public func settingsURL(for kind: PermissionKind) -> URL // x-apple.systempreferences:…
}
```

UI uses `microphone`/`systemAudio` to show inline denial banners with `settingsURL(for:)` deep links.

---

## 5. `Recording` module

Owns the session lifecycle, storage paths, data-model wiring, system-audio prompt/inference, and
orphan recovery. Backed by a seam over `AudioRecorder` so tests run with a fake engine.

```swift
public struct RecordingState: Sendable, Equatable {
    public var isRecording: Bool
    public var elapsed: TimeInterval
    public var meetingID: UUID?
    public static let idle: RecordingState
}

public enum RecordingError: Error, Sendable, Equatable {
    case permissionDenied(PermissionKind)
    case engineFailed(String)
    case alreadyRecording
}

public protocol RecorderControlling: Sendable {          // seam over AudioCapture.AudioRecorder
    func requestPermissions(systemProbePath: URL) async -> Bool
    func start(paths: CapturePaths) async throws
    func stop() async
    func stateStream() -> AsyncStream<CaptureState>
    func probableSystemAudioDenied() async -> Bool
}

@MainActor @Observable
public final class RecordingController {
    public private(set) var state: RecordingState
    public private(set) var systemAudioWarning: Bool
    public private(set) var lastError: RecordingError?

    public init(
        store: DataStore,
        permissions: Permissions,
        storageRoot: URL,                                 // …/Application Support/Biscotti/Recordings
        makeRecorder: @escaping @Sendable () -> any RecorderControlling   // single-use per session
    )

    public func start() async                              // mic JIT → create meeting → link refs → start engine → pump state
    @discardableResult public func stop() async -> UUID?   // stop engine → mark presence → return meetingID to transcribe
    public func recoverOrphans() async                     // launch reconciliation (§7)
}
```

**Production wiring:** `makeRecorder` returns an adapter wrapping `AudioRecorder.live()`. Storage
paths: `storageRoot/<meetingID>/mic.aac` + `system.aac`. `start()` order: ensure mic permission
(`permissions.requestMicrophone()`); create the `Meeting` (auto-title `"Recording — <date>"`); create
the dir + a `.recording` marker file; `attachAudio` two `AudioFileRef`s (mic/system, real paths);
`recorder.start(paths:)`; spawn a Task pumping `stateStream()` → `state.elapsed`; after ~2 s call
`probableSystemAudioDenied()` and `permissions.noteSystemAudio(...)` + set `systemAudioWarning`.
`stop()`: `recorder.stop()`, delete the `.recording` marker, `markAudioPresence`, clear `state`,
return the meeting id.

---

## 6. `TranscriptionService` module

Orchestrates the shared `Transcriber` (long-lived XPC client). Seam for tests.

```swift
public enum JobStatus: Sendable, Equatable {
    case idle
    case downloadingModel(message: String)   // engine emits messages, not %, for download
    case transcribing
    case completed
    case failed(message: String, retriable: Bool)
}

public protocol Transcribing: Sendable {       // seam over Transcription.Transcriber (shared instance)
    func ensureModelsDownloaded(status: (@Sendable (String) -> Void)?) async throws
    func processAudio(mic: URL, system: URL, customVocabulary: [String]) async throws -> TranscriptResult
}

@MainActor @Observable
public final class TranscriptionService {
    public private(set) var jobs: [UUID: JobStatus]      // per meeting

    public init(store: DataStore, engine: any Transcribing)   // shared engine (not a factory)

    public func transcribe(meetingID: UUID) async        // resolve paths → ensure models → run → persist+promote
    public func reTranscribe(meetingID: UUID) async       // same path, new version
}
```

`transcribe` flow: `store.audioPaths(meetingID:)` → set `.downloadingModel`/`.transcribing` →
`engine.ensureModelsDownloaded { msg in self.jobs[id] = .downloadingModel(message: msg) }` →
`engine.processAudio(mic:system:customVocabulary: [])` → `store.addTranscript(result,
vocabularyUsed: [], mappedEventIdentifier: nil, to: id)` → `store.setPreferredTranscript(newID,
for: id)` → `.completed`. Errors map to `.failed(message:, retriable:)` (engine
`workerInterrupted`/download/disk are retriable). **One job at a time** in the MVP (`// TODO` queueing).

**Production wiring:** `engine` = `TranscriberAdapter(Transcriber(backend: .hosted(serviceName:
"net.scosman.biscotti.BiscottiTranscriber")))`.

---

## 7. Orphan recovery (crash safety)

- On `start()`, `Recording` writes a `.recording` marker file in `storageRoot/<meetingID>/`.
- On clean `stop()`, it deletes the marker.
- On launch, `recoverOrphans()` scans `storageRoot/*/` for surviving `.recording` markers (= app
  crashed mid-record). For each: `markAudioPresence(meetingID:)` (records real byte sizes / presence),
  delete the stale marker, and leave the meeting as a **completed-but-untranscribed** recording the
  user can transcribe. ADTS-AAC is valid up to the crash point, so the bytes are usable.
- Deterministic + unit-testable via a file-system seam (inject the storage root; tests create fake
  marker dirs). No SwiftData schema change (no new `Meeting` field).

---

## 8. `AppCore` (thin MVP coordinator)

The composition + coordination seam the app target constructs and the UI observes. Deliberately a
**thin slice** of the topology's `AppCore` (the full background-engine slice is Project 6).

```swift
public enum Route: Sendable, Equatable { case empty, recording, meeting(UUID) }

@MainActor @Observable
public final class AppCore {
    public let store: DataStore
    public let permissions: Permissions
    public let recording: RecordingController
    public let transcription: TranscriptionService
    public private(set) var route: Route
    public private(set) var summaries: [MeetingSummary]

    public init(store:permissions:recording:transcription:)   // for tests (inject fakes)
    public static func live(storageRoot: URL, transcriberServiceName: String) throws -> AppCore

    public func onLaunch() async             // recoverOrphans → reloadSummaries
    public func startRecording() async       // recording.start → route = .recording
    public func stopRecording() async        // id = recording.stop → reloadSummaries → route = .meeting(id) → transcription.transcribe(id)
    public func select(_ meetingID: UUID)    // route = .meeting(id)
    public func reloadSummaries() async
}
```

`AppCore.live` builds the on-disk `DataStore` (`storageRoot.appending("Biscotti.store")` via
`DataStore.Storage.onDisk(storageRoot)`), the live `Permissions`, a `RecordingController` with the
`AudioRecorder` adapter factory, and a `TranscriptionService` with the hosted `Transcriber` adapter.

---

## 9. UI modules (view models + views)

Each screen: a `@MainActor @Observable` view model reading `AppCore`/`DataStore` DTOs + a SwiftUI
view. View models unit-test headlessly; views are previewable. No live `@Model` in views.

- **`AppShellUI`** — `NavigationSplitView`; sidebar = Record button (disabled while recording) +
  recording indicator + `MeetingListUI` past list; detail routes on `AppCore.route`
  (`recording → RecordingView`, `meeting(id) → MeetingDetailView`, `empty → placeholder`).
- **`RecordingUI`** — binds `AppCore.recording.state` (elapsed, title) + a Stop button
  (`AppCore.stopRecording()`); blinking record dot; conditional system-audio warning banner.
- **`MeetingDetailUI`** — view model loads `store.meetingDetail(id:)` + observes
  `transcription.jobs[id]`; renders the three states (downloading/transcribing · transcript ·
  failed+Retry); header with Re-transcribe (`transcription.reTranscribe(id:)`).
- **`MeetingListUI`** — renders `AppCore.summaries`; selection → `AppCore.select(id)`.
- **`DesignSystem`** — tokens + `RecordButton`, `StatusRow`, `TranscriptSegmentRow`, `Banner`.

---

## 10. App target & XPC wiring (`App/`)

Replicate the proven `ManualTestApp` wiring into `App/project.yml`:

- **Packages:** add `Transcription` and `AudioCapture` path packages (alongside `BiscottiKit`).
  (App-target deps: `BiscottiKit` products `AppShellUI`, `AppCore`, `DataStore`. `Transcription`/
  `AudioCapture` arrive transitively via the modules, but the **XPC target** needs `Transcription`
  directly.)
- **`BiscottiTranscriber` xpc-service target:** identical to `ManualTestApp/project.yml` — sources
  `../XPCServices/BiscottiTranscriber` (excluding plist/entitlements), depends on `Transcription`,
  bundle id `net.scosman.biscotti.BiscottiTranscriber`.
- **App target:** depend on the three BiscottiKit products + `BiscottiTranscriber` (`embed: true`).
- **Entitlements** (`App/Biscotti.entitlements`): keep `com.apple.security.device.audio-input`
  (covers mic + system-audio taps); non-sandboxed.
- **Info.plist** (`App/Resources/Info.plist`): add `NSMicrophoneUsageDescription` +
  `NSAudioCaptureUsageDescription` usage strings.
- **Composition root** (`App/Sources/BiscottiApp.swift`): build
  `AppCore.live(storageRoot: appSupportBiscotti, transcriberServiceName: "net.scosman.biscotti.BiscottiTranscriber")`,
  `.task { await core.onLaunch() }`, present `AppShellView(core: core)` in a single `WindowGroup`
  (regular activation, **no** `MenuBarExtra`). `// TODO` license attribution before ship.

`storageRoot` = `…/Library/Application Support/Biscotti/` (same root the model cache already uses);
recordings under `…/Biscotti/Recordings/<meetingID>/`.

---

## 11. Package.swift changes (`BiscottiKit`)

Add the nine targets above (+ test targets) and three new library products (`AppShellUI`, `AppCore`,
plus the existing `DataStore`). UI targets depend on each other per §1. `Recording` adds the
`AudioCapture` package dependency; `TranscriptionService` reuses the existing `Transcription`
dependency. All targets keep the `warningsAsErrors` setting and Swift 6 mode.

---

## 12. Testing seams (gating, hardware-free)

| Module | Seam(s) | Fake in tests |
|---|---|---|
| `Permissions` | `MicAuthorizing` | scripted statuses/requests |
| `Recording` | `RecorderControlling` factory + injected `storageRoot` + in-memory `DataStore` | a fake recorder (emits a `CaptureState` stream; configurable denial/throw); temp dir for markers |
| `TranscriptionService` | `Transcribing` + in-memory `DataStore` | a fake engine returning a canned `TranscriptResult` / throwing retriable errors |
| `AppCore` | constructed from the above fakes | full headless flow: start→stop→transcribe; orphan recovery; routing |
| UI VMs | constructed from a fake `AppCore`/DTOs | routing, state rendering, status rendering |

Coverage targets the **MVP flow**: start creates+links, stop finalizes+enqueues, transcribe
persists+promotes, re-transcribe versions, orphan recovery reconciles, permission denial surfaces,
routing transitions. `build_app` (non-gating) proves the app + embedded XPC compile/link.

---

## 13. Decisions log

- **Thin `AppCore` now** (vs. coordination in the app target): keeps the app target glue-only and the
  coordination unit-testable. A deliberate thin slice of the topology's `AppCore`; Project 6 deepens it.
- **`@MainActor @Observable` services, actors for heavy work**: idiomatic Swift-6 SwiftUI; no main-thread
  blocking; streams pumped into observable state.
- **Sendable DTOs from `DataStore`** (not live `@Model` in UI): clean strict-concurrency + testable VMs.
  Additive to DataStore; the root architecture's note #3 explicitly sanctions a mappers/DTO addition.
- **System-audio permission handled in `Recording`** (not `Permissions`): keeps `Permissions` free of
  `AudioCapture`, honoring the topology; mic stays fully in `Permissions`.
- **Marker-file orphan recovery** (no schema change): avoids a SwiftData migration for one MVP flag.
- **Single recording / single transcription job**: sufficient for the MVP; concurrency is `// TODO`.
