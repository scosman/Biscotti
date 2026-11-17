---
status: complete
---

# Component: Runner app (`STTLabRunner`)

Spec: functional_spec §4. An SPM executable target with a SwiftUI app. It links `STTLabCore` only. It is built on the home Mac (macOS 15, Xcode 26.x SDK) and runs on the runner Mac (macOS 27). All Speech code is behind `@available(macOS 26, *)` / `if #available(macOS 26, *)`.

## 1. Files

```
Sources/STTLabRunner/
  RunnerApp.swift            # @main App; one WindowGroup; CLI-mode switch
  RunnerView.swift           # the single window
  RunnerModel.swift          # @MainActor @Observable state + actions
  RunnerJob.swift            # bundle load, resume logic, per-meeting loop (no Speech import)
  AppleTranscription.swift   # @available(macOS 26, *) — the only file that imports Speech
  ResultsWriter.swift        # results folder, run.json, log.txt, apple.json
Sources/STTLabCore/
  AppleMeetingResult.swift   # schema (shared with analyze)
  RunnerResume.swift         # pure resume decision (tested)
```

## 2. Schema (`STTLabCore/AppleMeetingResult.swift`)

```swift
public struct AppleMeetingResult: Codable, Sendable {
    public var schemaVersion: Int                 // SchemaVersions.appleResult
    public var bundleID: UUID
    public var meetingID: String
    public var status: RunStatus                  // completed / failed / unsupportedLocale
    public var requestedLocale: String
    public var resolvedLocale: String?            // SpeechTranscriber.supportedLocale(equivalentTo:)
    public var config: AppleConfig
    public var assets: AssetEvent?
    public var timing: TimedRun?                  // analyze call through end of results
    public var audioDurationSeconds: Double
    public var memory: MemoryReport?
    public var results: [AppleResult]
    public var error: ErrorInfo?
}
public struct AppleConfig: Codable, Sendable {
    public var module: String                     // "SpeechTranscriber"
    public var transcriptionOptions: [String]     // []
    public var reportingOptions: [String]         // ["alternativeTranscriptions"]
    public var attributeOptions: [String]         // ["audioTimeRange", "transcriptionConfidence"]
    public var inputPath: String                  // "analyzeSequence(from: AVAudioFile)"
}
public struct AssetEvent: Codable, Sendable {
    public var installNeeded: Bool                // assetInstallationRequest returned non-nil
    public var startedAt: Date?; public var finishedAt: Date?
    public var progressTotalUnitCount: Int64?     // a hint of the download size
    public var error: ErrorInfo?
}
public struct CMTimeValue: Codable, Sendable, Equatable {   // lossless CMTime
    public var value: Int64; public var timescale: Int32; public var flags: UInt32; public var epoch: Int64
    public var seconds: Double?                   // nil when not numeric
}
public struct AppleResult: Codable, Sendable {
    public var index: Int
    public var rangeStart: CMTimeValue
    public var rangeDuration: CMTimeValue
    public var resultsFinalizationTime: CMTimeValue
    public var isFinal: Bool
    public var text: String                       // String(result.text.characters)
    public var runs: [AppleRun]
    public var alternatives: [AppleAlternative]
}
public struct AppleRun: Codable, Sendable {
    public var text: String
    public var charOffset: Int                    // offset in `text` (Character count), for grouping
    public var charLength: Int
    public var timeStart: CMTimeValue?            // run.audioTimeRange?.start
    public var timeDuration: CMTimeValue?         // run.audioTimeRange?.duration
    public var confidence: Double?                // run.transcriptionConfidence
    public var attributesDebug: String            // String(describing: run.attributes) — every attribute present
}
public struct AppleAlternative: Codable, Sendable { public var text: String; public var runs: [AppleRun] }

public struct RunnerSession: Codable, Sendable {  // appended to run.json
    public var sessionID: UUID
    public var bundleID: UUID
    public var appVersion: String
    public var machine: MachineInfo
    public var startedAt: Date; public var endedAt: Date?
    public var speechTranscriberAvailable: Bool
    public var supportedLocales: [String]         // identifiers
    public var installedLocales: [String]
    public var force: Bool
    public var meetingsAttempted: [String]; public var meetingsSkipped: [String]
}
public struct RunFile: Codable, Sendable { public var schemaVersion: Int; public var sessions: [RunnerSession] }
```

`CMTimeValue` has an initializer from `CMTime` in the runner target, because Core does not import CoreMedia types into the schema. The fields are plain integers.

## 3. Job flow (`RunnerJob`, an actor)

```swift
actor RunnerJob {
    init(bundleURL: URL, resultsURL: URL, force: Bool, log: RunLog, progress: @Sendable (RunnerProgress) -> Void)
    func loadBundle() throws -> LoadedBundle   // manifest + metas; validates schema version + files
    func run() async -> RunSummary
}
struct RunnerProgress: Sendable { var meetingIndex: Int; var meetingCount: Int; var meetingID: String
    var meetingFraction: Double; var elapsedSeconds: Double; var state: String }
```

1. `loadBundle`: read `manifest.json`. If `schemaVersion != SchemaVersions.bundle`, throw `bundleVersionMismatch(found:expected:)`. The UI shows both numbers. Read each `meta.json` and check that `audio.wav` exists. The SHA-256 check runs per meeting just before transcription (it reads 230 MB, so it is not done at load). A mismatch is a per-meeting failure ("audio file damaged in transfer").
2. Results folder: create `meetings/`. Load or create `run.json` and append a new `RunnerSession` (machine, availability, supported/installed locales). Rewrite `run.json` atomically at the start and at the end.
3. For each meeting in manifest order: `RunnerResume.shouldRun(existing: AppleMeetingResult?, force: Bool) -> Bool`. It returns true when there is no file, when `force`, or when `status == .failed`. Otherwise skip, and log "m03 already completed — skipped".
4. Run `AppleTranscription.transcribe(meta:audioURL:bundleID:log:progress:)` (macOS 26+) → `AppleMeetingResult`. Any thrown error is caught: write a `failed` result with `ErrorInfo`, then continue.
5. Write `meetings/<mid>/apple.json` atomically as soon as that meeting ends.
6. On macOS < 26 or `SpeechTranscriber.isAvailable == false`: do not run. The UI shows "Needs macOS 26+ with Speech support". CLI mode exits with code 2.

## 4. Apple transcription (`AppleTranscription.swift`, macOS 26+)

```swift
@available(macOS 26, *)
enum AppleTranscription {
    static func transcribe(meta: MeetingMeta, audioURL: URL, bundleID: UUID,
                           log: RunLog, progress: @Sendable (Double) -> Void) async throws -> AppleMeetingResult
}
```

Steps:

1. `guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: meta.appleLocale))`. If nil, return a result with `status = .unsupportedLocale` and no error.
2. `let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.alternativeTranscriptions], attributeOptions: [.audioTimeRange, .transcriptionConfidence])`.
3. Assets: `if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber])`, record `installNeeded = true` and the start time, log "downloading Apple speech assets for <locale>", run `try await request.downloadAndInstall()`, then record the end time and `request.progress.totalUnitCount`. An error here becomes a `failed` result with `assets.error` set.
4. `let file = try AVAudioFile(forReading: audioURL)`. `let analyzer = SpeechAnalyzer(modules: [transcriber])`.
5. Start the `MemorySampler(interval: 0.5, watchSystemProcesses: true)`. Record `start = Date()`.
6. Collector: `let collector = Task { var out: [AppleResult] = []; for try await r in transcriber.results { out.append(convert(r, index: out.count)); progress(r.resultsFinalizationTime.seconds / duration) }; return out }`. It is started **before** the analysis.
7. `let last = try await analyzer.analyzeSequence(from: file)`. Then `if let last { try await analyzer.finalizeAndFinish(through: last) } else { await analyzer.cancelAndFinishNow() }`.
8. Watchdog: wait for `collector.value`, with a timeout of `max(600, duration)` s after finalize (a task group races the collector against `Task.sleep`). On timeout: `collector.cancel()`, then throw `appleTimeout`. The partial results are lost on this path, and the error says so.
9. Stop the sampler and build the result (`completed`, even with zero results; spec §7 "empty result").
10. Any error from steps 4–8: cancel the collector, call `await analyzer.cancelAndFinishNow()`, and rethrow. Per Apple, the analyzer is finished after an error. A new analyzer is created for each meeting anyway.

`convert(_ r: SpeechTranscriber.Result, index:)`:

- `text = String(r.text.characters)`.
- Runs: `for run in r.text.runs`. `charOffset` = `r.text.characters.distance(from: r.text.startIndex, to: run.range.lowerBound)`, `charLength` = the distance across `run.range`, `text = String(r.text[run.range].characters)`. Time = `run.audioTimeRange` (start, duration). Confidence = `run.transcriptionConfidence`. `attributesDebug = String(describing: run.attributes)`.
- `alternatives = r.alternatives.map { same conversion }`. If the first alternative equals the main text, keep it anyway (lossless).
- `rangeStart = r.range.start`, `rangeDuration = r.range.duration`, `resultsFinalizationTime`, `isFinal`.

The coding agent must check the exact property names against the SDK's `Speech.swiftinterface` (`…/MacOSX.sdk/System/Library/Frameworks/Speech.framework/…/arm64e-apple-macos.swiftinterface`) and the Foundation `AttributeScopes.SpeechAttributes`. The signatures in steps 1–7 were checked against SDK 26.2.

## 5. UI (`RunnerView` + `RunnerModel`)

One window, about 720×560. There is no design doc (the user skipped UI design for the experiment).

- Header: the app name. A status line: macOS version, "SpeechTranscriber available: yes/no".
- "Choose Bundle…" (`NSOpenPanel`, directories only). After load: the bundle id (short), the meeting count, total audio hours, and the results folder path, with a "Change…" button.
- A table: Meeting | Duration | Locale | Status (pending / running n% / completed / skipped (done) / failed / unsupported locale).
- Controls: "Run" (disabled while running or when not available), "Re-run all (force)" checkbox, "Stop after current meeting".
- Progress: "Meeting 3 of 10 · m03 · 42% · elapsed 12:31". An overall `ProgressView`.
- Log: a scrolling monospaced text view with the last 200 lines.
- When done: "Reveal Results in Finder" (`NSWorkspace.shared.activateFileViewerSelecting([resultsURL])`).
- While running: `ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason:)`, so the Mac does not sleep.

`RunnerModel` holds the `RunnerJob` and maps progress callbacks to the main actor.

## 6. CLI mode

In `RunnerApp.init`: if `CommandLine.arguments` contains `--cli`, run `RunnerCLI.main()`. That function parses `--cli <bundle> [--results <dir>] [--force]`, runs the same `RunnerJob` with a `RunLog` that echoes to stdout, and calls `exit(code)` (0 = all completed or skipped, 1 = some failed, 2 = not available or bad bundle) before any window opens. Use: `STTLabRunner.app/Contents/MacOS/STTLabRunner --cli ~/Downloads/bundle`.

## 7. Packaging (`scripts/package_runner.sh`)

A human runs it on the home Mac (agents cannot run `swift build` in the sandbox):

```bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product STTLabRunner
BIN=$(swift build -c release --product STTLabRunner --show-bin-path)/STTLabRunner
APP=build/STTLabRunner.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/STTLabRunner"
cat > "$APP/Contents/Info.plist" <<'PLIST' … PLIST
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --verbose "$APP"
ditto -c -k --keepParent "$APP" build/STTLabRunner.zip
echo "Built $APP and build/STTLabRunner.zip"
```

`Info.plist` keys:

- `CFBundleIdentifier = net.scosman.sttlab.runner`. This is **not** the Biscotti id, so it causes no TCC interference.
- `CFBundleName`/`CFBundleExecutable = STTLabRunner`, `CFBundlePackageType = APPL`, `CFBundleShortVersionString = 1.0`, `CFBundleVersion = 1`.
- `LSMinimumSystemVersion = 15.0`, so the app opens on older macOS and shows its "needs macOS 26" message.
- `NSHighResolutionCapable = true`, `NSPrincipalClass = NSApplication`.
- `NSSpeechRecognitionUsageDescription` = "Transcribes test meetings on this Mac for an experiment." This is insurance only; per the research, SpeechAnalyzer does not need the permission.

No hardened runtime and no entitlements (the app is not notarized and not sandboxed).

## 8. Tests

The Speech code cannot run on macOS 15 CI or the home Mac. Tests cover:

- `RunnerResume.shouldRun` (all cases).
- `AppleMeetingResult` JSON round trip with a hand-built value (in `STTLabCoreTests`).
- `RunnerJob.loadBundle` on a temp bundle: valid; schema mismatch → `bundleVersionMismatch`; missing WAV → error. `RunnerJob` is in the executable target. To test it, the bundle-loading logic goes in `STTLabCore/BundleLoader.swift` (pure Foundation), and `RunnerJob` calls it.
