---
status: complete
---

# Component: `sttlab` CLI — prep and home engines

Targets: `STTLabHome` (library) and `sttlab` (executable, ArgumentParser). Spec: functional_spec §3. Shared types: architecture §3.

## 1. Command surface

```
sttlab select    --workspace W [--store-root R] [--short 5] [--long 5]
sttlab confirm   --workspace W
sttlab bundle    --workspace W [--force]
sttlab whisper   --workspace W [--meeting m03]… [--force]
sttlab diarize   --workspace W [--meeting m03]… [--force]
sttlab reference --workspace W [--meeting …] [--force] [--model microsoft/mai-transcribe-2]
                 [--chunk-seconds 300] [--no-zdr] [--probe] [--yes]
sttlab home-run  --workspace W [--yes]          # whisper, then diarize, then reference
sttlab analyze   --workspace W --results PATH [--out W/report]
```

- `--workspace` defaults to `~/STTLabData/default`. `--store-root` defaults to `~/Library/Application Support/Biscotti`.
- Every command opens a `RunLog` at `W/home/logs/<command>-<timestamp>.log`.
- `sttlab` is an `AsyncParsableCommand` with subcommands. Each subcommand calls one function in `STTLabHome`, so tests can call the logic without the CLI.

## 2. Store reader (`StoreReader.swift`)

```swift
public struct CandidateMeeting: Codable, Sendable, Equatable {
    public var meetingUUID: UUID
    public var title: String
    public var date: Date                 // startDate ?? createdAt
    public var durationSeconds: Double    // recordingDuration ?? last segment endTime
    public var micPath: String
    public var systemPath: String
    public var speakerCount: Int          // distinct non-nil segment speakerIDs
    public var wordCount: Int             // whitespace tokens over all segment texts
    public var language: String           // TranscriptRecord.language
    public var wordsPerMinute: Double { Double(wordCount) / max(durationSeconds / 60, 1) }
}

public enum StoreReader {
    public static func loadCandidates(storeRoot: URL, scratch: URL, log: RunLog) async throws
        -> (eligible: [CandidateMeeting], rejected: [(title: String, reason: String)])
}
```

Steps:

1. If an app with bundle id `net.scosman.biscotti` is running (`NSRunningApplication.runningApplications(withBundleIdentifier:)`), log a warning: "Quit Biscotti for a consistent snapshot". Continue.
2. Copy `Biscotti.store`, `Biscotti.store-wal` and `Biscotti.store-shm` (those that exist) into `scratch` (`W/home/store_snapshot/`). The production store is never opened.
3. `let store = try DataStore(storage: .onDisk(scratch))`. Then `try await store.read { s in try s.recentMeetings(limit: 100_000).map(project) }`. `project` runs on the actor and returns `Sendable` values only:
   - transcript = the one with `id == meeting.preferredTranscriptID`, else the newest by `createdAt`, else none;
   - mic/system = the `audioFiles` with `role == .mic` / `.system`;
   - segments sorted by `index`.
4. Eligibility (rejected with a reason otherwise): mic and system refs exist, and `FileManager.isReadableFile` is true for both paths; a transcript exists; `speakerCount >= 2`; `durationSeconds > 0`.
5. Delete `scratch` at the end (it holds all meetings' data), also on error (`defer`).

## 3. Selection (`Selection.swift`)

```swift
public enum Bucket: String, Codable, Sendable { case short, long }
public struct SelectionEntry: Codable, Sendable, Equatable {
    public var meetingUUID: UUID; public var title: String; public var date: Date
    public var durationSeconds: Double; public var speakerCount: Int; public var wordCount: Int
    public var wordsPerMinute: Double; public var language: String
    public var bucket: Bucket?            // nil = shortfall fill
    public var appleLocale: String        // default "en_US"
    public var meetingID: String?         // "m01"…, set by confirm
}
public struct SelectionFile: Codable, Sendable {
    public var schemaVersion: Int
    public var createdAt: Date
    public var notes: [String]            // shortfall messages etc.
    public var meetings: [SelectionEntry]
    public var alternates: [SelectionEntry]   // up to 10 next-best, for swaps
    public var confirmed: Bool
    public var confirmedAt: Date?
    public var confirmedHash: String?
}
public enum Selector {
    public static func propose(_ candidates: [CandidateMeeting], short: Int, long: Int) -> SelectionFile
}
```

Algorithm (deterministic; ties broken by `meetingUUID.uuidString` order):

1. Bands (minutes): short = [25, 40], long = [50, 75].
2. For each bucket, `pick(k, from: band)` with **greedy max-min variety**:
   - Normalize each candidate to `x = (dateDays − minDays) / max(rangeDays, 1)` and `y = (wpm − minWpm) / max(rangeWpm, 1)`, computed over that band.
   - Start with the candidate whose wpm is closest to the band median.
   - Then repeat: pick the candidate that maximizes `min over chosen c of (|x − x_c| + |y − y_c| + (speakerCount != c.speakerCount ? 0.5 : 0))`.
3. Shortfall: if a band has fewer than k candidates, fill from the not-yet-chosen candidates sorted by `|duration − center|` (center 30 min for short, 60 min for long), with `bucket = nil`. Add a note, for example: "short bucket: 3 in band, 2 filled from nearest durations".
4. If fewer than `short + long` eligible in total, take all and add a note.
5. Order `meetings` short first, then long, then by date. `alternates` = the next 10 by the same variety score against the chosen set.
6. `appleLocale = "en_US"` for all. If `language` is not `"en"`, add a note: "m?? language is de; set appleLocale before confirm".

`select` writes `W/selection.json` (it refuses to overwrite a confirmed selection without `--force`). It prints a table: index, date (yyyy-MM-dd), duration (min), speakers, words, wpm, bucket, title. Then it prints: "Edit selection.json (remove entries, move entries from alternates, set appleLocale), then run `sttlab confirm`."

## 4. Confirm (`Confirm.swift`)

- Reads `selection.json`. It must have 1…20 meetings, unique UUIDs, and each `appleLocale` must be non-empty.
- Assigns `meetingID = String(format: "m%02d", i + 1)` in file order.
- `confirmedHash` = SHA-256 hex of the canonical JSON (sorted keys) of `[(meetingID, meetingUUID, appleLocale)]`.
- It prints the final list and the data-flow notice: "Audio for these N meetings (H.h hours) will be copied to the bundle, and will be uploaded to OpenRouter (<model>) by `sttlab reference`." Then it writes `confirmed = true`, `confirmedAt`.
- `ConsentGate.require(workspace:)` is used by bundle/whisper/diarize/reference. It throws `confirmationRequired` if `confirmed == false` or the recomputed hash differs ("selection.json changed after confirm; run confirm again").

## 5. Bundle (`BundleBuilder.swift`)

For each confirmed entry (skip if `bundle/meetings/<mid>/meta.json` exists and not `--force`):

1. Copy mic/system `.aac` to `home/source/<mid>/`. Write `source.json` = the `SelectionEntry` (title, date, UUID).
2. `mic = AudioProcessor.loadAudioAsFloatArray(fromPath:)`, same for system (WhisperKit). Then `merged = try AudioMerger.merge(mic:system:)` (production).
3. `WAVFile.writeFloat32Mono16k(merged.samples, to: bundle/meetings/<mid>/audio.wav)`.
4. Write `meta.json` (`MeetingMeta`, with `durationSeconds = merged.duration` and `audioSHA256`).

Then write `manifest.json` (a new `bundleID` only when the manifest does not exist yet; a rebuild keeps the id) and `README.txt` (text in §8). Print the bundle size and "AirDrop the `bundle` folder to the runner Mac."

## 6. Home engine runs (`WhisperRunner.swift`, `DiarizationRunner.swift`)

Both load the samples with `AudioProcessor.loadAudioAsFloatArray(fromPath: audio.wav)`. They load models once per command and process meetings in manifest order.

```swift
public struct WhisperOutput: Codable {             // home/whisper/<mid>.json
    public var schemaVersion: Int
    public var meetingID: String
    public var status: RunStatus                    // .completed / .failed
    public var settings: [String: String]           // model, repo, wordTimestamps, argmax version "1.0.0"
    public var machine: MachineInfo
    public var modelLoadSeconds: Double?            // first meeting only; else nil
    public var timing: TimedRun?                    // transcribe call only
    public var audioDurationSeconds: Double
    public var memory: MemoryReport?
    public var results: [TranscriptionResult]?      // raw WhisperKit output (Codable)
    public var error: ErrorInfo?
}

public struct SavedDiarization: Codable, Sendable {
    public var speakerCount: Int
    public var totalFrames: Int
    public var frameRate: Float
    public var segments: [SavedSpeakerSegment]
}
public struct SavedSpeakerSegment: Codable, Sendable {
    public var speaker: SpeakerInfo                 // SpeakerKit enum, Codable
    public var startFrame: Int; public var endFrame: Int
    public var startTime: Float; public var endTime: Float   // informational
}
public struct DiarizationOutput: Codable {         // home/diarization/<mid>.json
    public var schemaVersion: Int; public var meetingID: String; public var status: RunStatus
    public var settings: [String: String]; public var machine: MachineInfo
    public var timing: TimedRun?; public var audioDurationSeconds: Double
    public var memory: MemoryReport?
    public var diarization: SavedDiarization?
    public var timingsDescription: String?          // String(describing: result.timings)
    public var error: ErrorInfo?
}
extension SavedDiarization {
    public init(_ result: DiarizationResult)
    public func rebuild() -> DiarizationResult       // public generic init; segments via startFrame/endFrame
}
```

- `RunStatus` (in Core): `completed`, `failed`, `unsupportedLocale`.
- A `MemorySampler` runs around each `transcribe`/`diarize` call (it is reset per meeting).
- `MachineInfo`, settings and the argmax version are saved with every output.

## 7. Reference (`Reference/`)

### 7.1 Chunk planner (`ChunkPlanner.swift`)

```swift
public struct ChunkPlan: Codable, Sendable, Equatable {
    public var sampleRate: Double
    public var chunks: [Chunk]
    public struct Chunk: Codable, Sendable, Equatable {
        public var index: Int; public var startSample: Int; public var endSample: Int
        public var cutRMS: Float?            // RMS of the silence window at the start cut (nil for 0)
        public var startSeconds: Double { Double(startSample) / 16000 }
    }
}
public enum ChunkPlanner {
    public static func plan(samples: [Float], range: Range<Int>, targetSeconds: Double,
                            searchSeconds: Double = 30, windowSeconds: Double = 0.5,
                            hopSeconds: Double = 0.1, sampleRate: Double = 16000) -> [ChunkPlan.Chunk]
}
```

- `pos = range.lowerBound`. While `range.upperBound − pos > (targetSeconds + 60) * sr`: `target = pos + targetSeconds * sr`. Scan windows of `windowSeconds` at `hopSeconds` steps whose centers are in `[target − search, target + search]` (clamped to the range). Take the window with the minimum RMS (first one on ties). The cut is at the window center. Append `[pos, cut)`. Then `pos = cut`.
- The last chunk is `[pos, upperBound)`. So no chunk is longer than `target + 60` s, except a final chunk (at most `target + 60`).
- Chunk indices are renumbered `0…n−1` after any split. Splits only happen to chunks that have no saved response yet, so saved responses keep their own `startSample` in `chunk_NNN.meta.json`. Analyze uses the meta's `startSample`, not the index.

### 7.2 Client (`OpenRouterClient.swift`)

```swift
public protocol HTTPTransport: Sendable {
    func post(url: URL, headers: [String: String], body: Data, timeout: TimeInterval) async throws -> (Int, [String: String], Data)
}
public struct URLSessionTransport: HTTPTransport { … }   // URLSession.shared; timeout 180 s

public struct TranscriptionRequest: Sendable {
    public var model: String; public var wavData: Data; public var language: String?
    public var zdr: Bool
    public func jsonBody() throws -> Data
    // {"model":…, "input_audio":{"data":<base64>,"format":"wav"}, "language":"en",
    //  "response_format":"verbose_json", "timestamp_granularities":["word","segment"],
    //  "provider":{"zdr":true}}   — "provider" omitted when zdr == false
    public func metadata() -> [String: String]   // everything except the audio data. No headers.
}

public struct OpenRouterClient: Sendable {
    public init(apiKey: String, transport: any HTTPTransport,
                endpoint: URL = URL(string: "https://openrouter.ai/api/v1/audio/transcriptions")!)
    public func transcribe(_ req: TranscriptionRequest) async -> AttemptOutcome
}
public enum AttemptOutcome: Sendable {
    case success(status: Int, headers: [String: String], body: Data)
    case retryable(status: Int?, message: String)    // network error, 408, 429, 5xx except below
    case timeoutLike(status: Int?, message: String)  // URLError.timedOut, 408, 502, 504
    case fatal(status: Int, body: Data)              // other 4xx (400, 401, 402, 403, 404, 413…)
}
```

Headers: `Authorization: Bearer <key>`, `Content-Type: application/json`, `HTTP-Referer: https://github.com/scosman/biscotti`, `X-Title: Biscotti STT experiment`.

Retry policy (`ReferenceRunner`), per chunk:

- `retryable`: up to 4 more attempts, with sleeps of 2, 4, 8 and 16 s (`Retry-After` header wins if present, capped at 60 s).
- `timeoutLike`: retry once. A second `timeoutLike` splits the chunk (when the split depth is < 3) into a new plan for its range with `targetSeconds = chunkLength / 2`. Otherwise it is a failure.
- `fatal`: stop for this chunk; save status, headers and body; mark the meeting failed. If status is 401, 402 or 403, stop the whole command (bad key, no credit, or ZDR has no endpoint) and print the body.
- `413`: treated like `timeoutLike` (split).

### 7.3 Response parsing (`ReferenceResponse.swift`)

```swift
public struct ReferenceResponse: Decodable, Sendable {
    public var text: String?
    public var language: String?
    public var duration: Double?
    public var segments: [Seg]?
    public var words: [Word]?
    public var usage: Usage?
    public var model: String?
    public var provider: String?
    public struct Seg: Decodable, Sendable { public var start: Double; public var end: Double; public var text: String; public var speaker: String? }
    public struct Word: Decodable, Sendable { public var word: String; public var start: Double; public var end: Double; public var confidence: Double?; public var speaker: String? }
    public struct Usage: Decodable, Sendable { public var seconds: Double?; public var cost: Double? }
}
```

All fields are optional. The raw body is always saved as-is (`chunk_NNN.response.json`), so a parse change never needs a re-upload.

### 7.4 Files and flow (`ReferenceRunner.swift`)

- `reference/<mid>/plan.json` is written once (re-planned only by `--force`).
- For each chunk without a saved 200 response: build the 16-bit WAV with `WAVFile.int16WAVData`, send, and save `chunk_NNN.response.json` (raw body) and `chunk_NNN.meta.json`. The meta has the request metadata, `startSample`, `endSample`, HTTP status, response headers (all; OpenRouter does not echo the key), attempts, latency seconds, and `requestedAt`.
- `reference/<mid>/status.json`: `{status, model, zdr, chunkCount, completedChunks, totalCost, wordsPresent: Bool, error?}`.
- Before any upload: if `--yes` is not given, print the meeting count, total audio hours, estimated cost (`hours × 0.10`, from `--price-per-hour`, default 0.10), the model and the ZDR flag, and ask `Proceed? [y/N]` on stdin. If stdin is not a TTY and `--yes` is missing, refuse.
- `--probe`: take the first meeting, the first 60 s (`[0, 960_000)`), send it, and save to `reference/probe/`. Print the HTTP status, `words` count and the first 10 words with times, segments count, `usage.cost`, and the `provider`/`model` fields if present. Exit. The probe does not need `--yes`; it still needs the confirmed selection.
- One model per workspace: `status.json` saves the model. If `--model` differs from a saved completed status, refuse unless `--force` (spec §3.5: one reference for the whole bundle).

## 8. `README.txt` (written into the bundle)

```
STT Lab — runner instructions (macOS 26 or later)

1. Copy STTLabRunner.app to this Mac (for example to Applications).
2. Open it. If macOS says it cannot verify the app: open System Settings →
   Privacy & Security, scroll down, and click "Open Anyway" for STTLabRunner.
   (Or in Terminal: xattr -dr com.apple.quarantine /path/to/STTLabRunner.app)
3. Click "Choose Bundle…" and select this folder.
4. Click "Run". Keep the Mac awake and plugged in. It takes about 1–2 hours.
   You can quit and run again; finished meetings are kept.
5. When done, click "Reveal Results" and AirDrop the "<this folder>-results"
   folder back.
The app makes no network connections except Apple's own speech-model download
(if the model is not installed yet).
```
