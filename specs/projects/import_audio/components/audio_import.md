---
status: complete
---

# Component: AudioImport

## 1. Purpose and scope

A new BiscottiKit library target, `Sources/AudioImport/`. It owns everything about *importing a file* that doesn't need AppKit or SwiftUI:

- Classifying files and declared types as supported or unsupported (functional spec §3).
- Converting a source file to the standard recording format (§6.1).
- Reading each item's meeting date (§6.2).
- The session-long ordered import list, its serial worker and its run counters (§4).
- Creating the imported meeting's on-disk audio and `DataStore` row (§6.3).
- The Import screen's header copy, as a pure function (§5.2).

**Not** its job:
- Drag-and-drop and file promises (AppKit, in `ImportUI`).
- Navigation and post-processing (AppCore, via the `onItemFinished` callback).
- Any view.

Dependencies:
- `DataStore`.
- `AudioCapture` (product): `EncoderSettings.voice` only.
- System frameworks: AVFoundation, AudioToolbox, CoreMedia, UniformTypeIdentifiers, os.

---

## 2. Public types

```swift
/// One thing to import, as handed over by the UI.
public enum ImportEntry: Sendable {
    /// A local file (Finder drag, open panel).
    case file(URL)
    /// A file promise (Voice Memos, Photos). `displayName` is the promised
    /// name if the source app supplied one. `deliver` resolves to the
    /// received file's URL (in a temp dir owned by the UI layer) or throws.
    case promised(displayName: String?, deliver: @Sendable () async throws -> URL)
}

public enum ImportItemStatus: Sendable, Equatable {
    case receiving              // promise not yet delivered
    case waiting
    case converting
    case done(meetingID: UUID)
    case failed(ImportFailure)
}

public enum ImportFailure: Error, Sendable, Equatable {
    case noAudio, sourceMissing, saveFailed, unreadable

    /// User-facing copy (functional spec §5.4).
    public var message: String {
        switch self {
        case .noAudio:       "This file has no audio."
        case .sourceMissing: "This file was moved or deleted."
        case .saveFailed:    "Couldn't save the converted audio."
        case .unreadable:    "Couldn't convert this file. It may be damaged."
        }
    }
}

public struct ImportItem: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let batchID: UUID
    public internal(set) var displayName: String     // file name incl. extension
    public internal(set) var sourceURL: URL?         // nil until a promise delivers
    public internal(set) var meetingDate: Date?      // nil until resolved
    public internal(set) var status: ImportItemStatus
    public let addedAt: Date
    public let isPromised: Bool
}

/// A stretch of continuous conversion work (functional spec §4.1).
public struct ImportRun: Sendable, Equatable {
    public let startIndex: Int   // index into `items` of the run's first item
    public var count: Int        // items in the run so far
}

/// Passed to `onItemFinished` after an item reaches `.done` or `.failed`.
public struct ImportFinished: Sendable {
    public let item: ImportItem
    public let batchSize: Int    // entries in the import action that added it
}
```

`ImportEntry` holds a closure, so it isn't `Equatable`. Tests compare items, not entries.

---

## 3. Classifier (`ImportFileClassifier.swift`)

```swift
public enum ImportFileClassifier {
    /// Supported iff `type` conforms to `.audio` or `.audiovisualContent`.
    public static func isSupported(_ type: UTType) -> Bool

    /// Classifies a local URL by cheap resource values only (never opens it).
    /// Directories and packages -> false. Unknown type -> false.
    public static func isSupported(fileURL: URL) -> Bool

    /// Classifies a declared type identifier (file promises).
    public static func isSupported(typeIdentifier: String) -> Bool

    /// The open panel's / fileImporter's filter.
    public static let allowedContentTypes: [UTType] = [.audio, .audiovisualContent]
}
```

- `isSupported(fileURL:)`:
  1. Read `try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .contentTypeKey])`.
  2. If `isDirectory == true` or `isPackage == true` → `false`.
  3. Type = `contentType ?? UTType(filenameExtension: url.pathExtension)`. A nil type → `false`.
  - When the file doesn't exist (a stale pasteboard), the resource values are nil and the extension fallback applies. Conversion later fails with `.sourceMissing`.
- `isSupported(typeIdentifier:)`: `UTType(id).map(isSupported) ?? false`.

---

## 4. Converter

### 4.1 Seam

```swift
public struct ConversionResult: Sendable, Equatable {
    public let duration: TimeInterval   // frames written / 24_000
    public let byteSize: Int64          // output file size on disk
}

public protocol AudioConverting: Sendable {
    /// Decodes `source`'s first enabled audio track and writes ADTS AAC-LC
    /// mono 24 kHz 64 kbps to `destination` (overwriting). On any failure
    /// the destination is removed before throwing.
    func convert(source: URL, destination: URL) async throws(ImportFailure) -> ConversionResult
}
```

If typed throws (`throws(ImportFailure)`) fights the toolchain with the AVFoundation calls inside, use plain `throws` and document that only `ImportFailure` is thrown. The controller maps any other error to `.unreadable` defensively.

### 4.2 Live implementation: `AVFoundationAudioConverter`

A `struct AVFoundationAudioConverter: AudioConverting`, with `let encoder = EncoderSettings.voice`. `convert` wraps the whole body in `try await Task.detached(priority: .userInitiated) { … }.value`.

Steps:

1. **Source check.** If `!FileManager.default.fileExists(atPath: source.path)` → `.sourceMissing`.
2. **Asset.** `let asset = AVURLAsset(url: source)`.
   - `if try await asset.load(.hasProtectedContent)` → `.unreadable`.
   - `let tracks = try await asset.loadTracks(withMediaType: .audio)`. Pick the first track where `try await track.load(.isEnabled)` holds, else `tracks.first`.
   - No track → `.noAudio`.
   - Any thrown load error → `.unreadable`.
3. **Reader.** `AVAssetReader(asset:)` (throws → `.unreadable`). Use an `AVAssetReaderTrackOutput(track:outputSettings:)` with:
   ```swift
   var mono = AudioChannelLayout(); mono.mChannelLayoutTag = kAudioChannelLayoutTag_Mono
   [AVFormatIDKey: kAudioFormatLinearPCM,
    AVSampleRateKey: encoder.sampleRate,          // 24_000
    AVNumberOfChannelsKey: 1,
    AVChannelLayoutKey: Data(bytes: &mono, count: MemoryLayout<AudioChannelLayout>.size),
    AVLinearPCMBitDepthKey: 32,
    AVLinearPCMIsFloatKey: true,
    AVLinearPCMIsNonInterleaved: false,
    AVLinearPCMIsBigEndianKey: false]
   ```
   Set `output.alwaysCopiesSampleData = false`. If `reader.canAdd(output)` fails, or `startReading()` returns false → `.unreadable`.
4. **Writer.** Create the parent directory, then:
   - `ExtAudioFileCreateWithURL(destination, encoder.fileType, &encoder.outputASBD(), nil, AudioFileFlags.eraseFile.rawValue, &file)`. A non-`noErr` status → `.saveFailed`.
   - Client format: `AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: true)!.streamDescription.pointee`, set via `kExtAudioFileProperty_ClientDataFormat`. Failure → `.saveFailed`.
   - `EncoderSettings.applyBitRate(to: file, bitRate: encoder.bitRate)`. A non-`noErr` status is logged as a warning, not a failure (the same as capture's `VPIOFileHelper`).
5. **Pump.** `while let sample = output.copyNextSampleBuffer()`:
   - `try Task.checkCancellation()` (map it to `.unreadable`).
   - `let frames = CMSampleBufferGetNumSamples(sample)`; skip 0.
   - `CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, bufferListSizeNeededOut: nil, bufferListOut: &abl, bufferListSize: MemoryLayout<AudioBufferList>.size, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block)`. A non-`noErr` status → `.unreadable`.
   - `ExtAudioFileWrite(file, UInt32(frames), &abl)`. A non-`noErr` status → `.saveFailed` (disk full lands here).
   - `totalFrames += frames`.
6. **Finish.**
   - After the loop: if `reader.status == .failed` → `.unreadable`.
   - `ExtAudioFileDispose(file)`. A non-`noErr` status → `.saveFailed`.
   - `totalFrames == 0` → `.noAudio`.
   - `byteSize` from `FileManager.attributesOfItem(...)[.size]`.
   - Return `ConversionResult(duration: Double(totalFrames) / 24_000, byteSize:)`.
7. **Cleanup.** Every throw path disposes the `ExtAudioFileRef` (if created), cancels the reader, and removes `destination`. Use a `defer` with a `succeeded` flag.

This mirrors the capture path's `ExtAudioFile` + `EncoderSettings` usage, so imports and recordings produce byte-compatible ADTS files that `AudioProcessor.loadAudioAsFloatArray` and the player already read.

### 4.3 Test fake (`BiscottiTestSupport/FakeAudioConverter.swift`)

```swift
public final class FakeAudioConverter: AudioConverting, @unchecked Sendable {
    /// Per-source-filename scripted outcome; default success(60s).
    public var outcomes: [String: Result<ConversionResult, ImportFailure>]
    /// If set, convert awaits this gate before finishing (to observe .converting).
    public var gate: AsyncGate?
    public private(set) var convertedSources: [URL]
    // Success writes a few dummy bytes to `destination` so moves succeed.
}
```

Use a lock for the mutable state.

---

## 5. Meeting-date reader

```swift
public protocol ImportMetadataReading: Sendable {
    /// Embedded media creation date, else file modification date, else nil.
    func meetingDate(for source: URL) async -> Date?
}

public struct AVFoundationMetadataReader: ImportMetadataReading { … }
```

Live implementation, inside `Task.detached`:
1. `let asset = AVURLAsset(url:)`.
2. If `let item = try? await asset.load(.creationDate)` and `let date = try? await item.load(.dateValue)` → return it.
3. Else, among `try? await asset.load(.metadata)`, the first item with `commonKey == .commonKeyCreationDate` whose `.dateValue` loads.
4. Else `try? source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate`.
5. Else nil.

The controller applies the final fallback and the clamp: `min(readDate ?? item.addedAt, item.addedAt)`.

---

## 6. Controller (`AudioImportController.swift`)

```swift
@MainActor @Observable
public final class AudioImportController {
    public private(set) var items: [ImportItem] = []
    public private(set) var run: ImportRun?

    /// True when any item is receiving, waiting or converting.
    public var hasPendingWork: Bool
    /// True while the worker is converting (drives the sidebar spinner).
    public var isConverting: Bool { items.contains { $0.status == .converting } }
    public var hasSession: Bool { !items.isEmpty }

    /// Called on the main actor after each item finishes (done or failed).
    @ObservationIgnored public var onItemFinished: (@MainActor (ImportFinished) async -> Void)?

    public init(
        store: DataStore,
        recordingsRoot: URL,
        converter: any AudioConverting = AVFoundationAudioConverter(),
        metadata: any ImportMetadataReading = AVFoundationMetadataReader(),
        now: @escaping @Sendable () -> Date = { Date() }
    )

    /// Appends entries (one import action) and starts the worker if idle.
    /// Returns the batch id. Empty input is a no-op returning a fresh id.
    @discardableResult public func add(_ entries: [ImportEntry]) -> UUID

    /// Removes `<recordingsRoot>/.import-staging` (crash leftovers).
    public nonisolated static func cleanStaging(recordingsRoot: URL)

    /// Test seam.
    package func awaitIdle() async

    /// Index of the item currently converting within the current run (1-based), or nil.
    public var runPosition: Int?
}
```

### 6.1 `add`

1. `let batchID = UUID()`, `let addedAt = now()`.
2. **Run tracking:**
   - If `!hasPendingWork` (idle) → `run = ImportRun(startIndex: items.count, count: entries.count)`.
   - Else `run?.count += entries.count`. If `run` is nil while work is pending, start one at the first pending index.
3. For each entry, create an `ImportItem`:
   - `.file(url)` → `displayName = url.lastPathComponent`, `sourceURL = url`, status `.waiting`.
   - `.promised(name, deliver)` → `displayName = name ?? "Incoming file"`, `sourceURL = nil`, status `.receiving`, `isPromised = true`. Then start `deliveryTasks[item.id] = Task { try await deliver() }` and a follow-up main-actor task:
     - On success: set `sourceURL`, `displayName = url.lastPathComponent`, status `.waiting` (if still `.receiving`), and start the date read.
     - On failure: status `.failed(.unreadable)`.
4. Append the items. For each `.file` item, start the date read: `Task { let d = await metadata.meetingDate(for: url); update item.meetingDate = clamp(d) }`.
5. `startWorkerIfNeeded()`.

### 6.2 Worker

`worker: Task<Void, Never>?`. It loops on the main actor:

```
while let index = items.firstIndex(where: { $0.status == .waiting || $0.status == .receiving }) {
    await process(index)
}
worker = nil; run = nil
```

Items are processed strictly in list order. A `.receiving` item at the head blocks the queue until its delivery resolves (FIFO). Failed-at-delivery items are skipped naturally, since they're already `.failed`.

`process(index)` (re-look-up the item by `id` after every `await`; never hold the index across awaits):

1. If `.receiving`: `await deliveryTasks[id]?.result`. Whatever the result, the follow-up task has updated the status. If it's now `.failed` → call `finish(id)` and return.
2. Set status `.converting`.
3. `let meetingDate = clamp(await dateTask(id) ?? nil)`. If the date read hasn't finished, await it (it's fast). Clamp: `min(d ?? addedAt, addedAt)`. Store it on the item.
4. `staging = recordingsRoot/.import-staging/<itemID>.aac`.
5. `let result = try await converter.convert(source: sourceURL!, destination: staging)`. A failure → `fail(id, failure)`.
6. `let meetingID = UUID()`, `dir = recordingsRoot/<meetingID>`, then `createDirectory`, then `moveItem(staging → dir/system.aac)`. Failure → remove `dir`, then `fail(.saveFailed)`.
7. `try await store.createImportedMeeting(id: meetingID, title: "Imported from \(displayName)", start: meetingDate, duration: result.duration, audioPath: dir/system.aac path, audioByteSize: result.byteSize)`. Failure → remove `dir`, then `fail(.saveFailed)`.
8. Set status `.done(meetingID)`.
9. If `isPromised`: remove the delivered file's parent temp directory.
10. `finish(id)`.

- `fail(id, f)`: remove `staging`, set status `.failed(f)`. If promised, remove its temp dir. Log. Then `finish(id)`.
- `finish(id)`: `await onItemFinished?(ImportFinished(item:, batchSize: batchSizes[batchID]))`.
- `batchSizes: [UUID: Int]` is recorded in `add`.

### 6.3 Storage layout

```
<recordingsRoot>/
  .import-staging/<itemID>.aac     # in-flight encode; hidden, so recoverOrphans skips it
  <meetingID>/system.aac           # final; same layout as a recording's system track
```

- No `.recording` marker is written. Imports aren't crash-recoverable recordings.
- A crash between the move (step 6) and the insert (step 7) leaves an unreferenced `<meetingID>/` folder. This is accepted (tiny window, harmless, a few MB), and documented in a code comment.

### 6.4 Header copy (`ImportHeaderCopy.swift`)

```swift
public struct ImportHeaderCopy: Equatable, Sendable {
    public let title: String
    public let status: String
    public let statusIsMono: Bool   // in-progress line uses mono (ui_design §3.1)

    public static func make(items: [ImportItem], run: ImportRun?, runPosition: Int?) -> ImportHeaderCopy
}
```

This implements the functional spec §5.2 table exactly.
- In progress = `run != nil`: title `Importing \(n) file(s)` with `n = run.count`.
  - Status for a 1-item run: `converting audio`.
  - Status for a longer run: `"\(i) of \(n) · converting audio"`, where `i = runPosition ?? 1`. While the head item is still receiving, `i` is that item's position.
- Complete:
  - `T = items.count`, `X = done count` (including done items whose meeting was deleted).
  - `X == T` → `Imported \(T) file(s)` + "Transcripts and summaries are being written in each meeting."
  - `0 < X < T` → `Imported \(X) of \(T) files` + the same status.
  - `X == 0` → `Imported 0 of \(T) file(s)` + "Couldn't convert these files." (or "Couldn't convert this file." when `T == 1`).
- Pluralization helper: `"\(n) " + (n == 1 ? "file" : "files")`.

---

## 7. Test plan (`Tests/AudioImportTests`)

### Classifier
- `isSupported_audioTypes`: wav, mp3, m4a, aac, aiff, caf, flac → true.
- `isSupported_movieTypes`: mp4, mov, m4v → true.
- `isSupported_otherTypes`: pdf, txt, png, unknown extension → false.
- `isSupported_directory_false`: a temp dir named `foo.wav/` → false.
- `isSupported_typeIdentifier`: `com.apple.m4a-audio` → true, `public.jpeg` → false, garbage → false.

### Converter (real files, temp dir; `AVAudioFile` writes the sources)
- `convert_stereo44kWav_producesMono24kADTS`:
  - The first two bytes of the output match ADTS sync (`0xFFF`).
  - `AVAudioFile(forReading:)` reports `sampleRate == 24_000` and `channelCount == 1`.
  - Duration within ±0.05 s of the source.
- `convert_mono48kWav_resamples`.
- `convert_sixChannelWav_downmixesToMono`.
- `convert_aacM4ASource_reencodes`: write an AAC `.m4a` via `AVAudioFile` with AAC settings first.
- `convert_zeroFrameWav_throwsNoAudio_andRemovesDestination`.
- `convert_garbageBytesWithM4AExtension_throwsUnreadable`.
- `convert_missingSource_throwsSourceMissing`.
- `convert_outputDecodesWithAudioProcessor`: optional, if `Transcription`'s loader is reachable from the test target. Otherwise skip.

### Metadata
- `meetingDate_noEmbeddedDate_usesModificationDate`: set the mtime via `setAttributes`.
- `meetingDate_missingFile_returnsNil`.

### Controller (`FakeAudioConverter`, in-memory `DataStore`, temp recordings root)
- `add_files_processedInOrder`.
- `add_whileRunning_extendsRun_andAppends`: 5, then 3 → 8 items, `run.count == 8`.
- `done_createsMeeting_withPlaceholderTitle_dateDuration_systemTrack`.
- `done_movesFileToMeetingDir_andClearsStaging`.
- `failed_conversion_leavesNoMeeting_andNoStaging`.
- `failed_storeInsert_removesMeetingDir_marksSaveFailed`: use a store fake or a pre-deleted root to force it.
- `meetingDate_future_clampedToAddedAt`.
- `meetingDate_nil_fallsBackToAddedAt`.
- `promised_delivered_updatesNameAndConverts`.
- `promised_deliveryThrows_failsUnreadable_queueContinues`.
- `promised_receivingAtHead_blocksUntilDelivered_FIFO`.
- `onItemFinished_calledPerItem_withBatchSize`.
- `run_clearedWhenIdle`.
- `runPosition_tracksConvertingItem`.
- `cleanStaging_removesDirectory`.

### Header copy
One test per row of the functional spec §5.2 table, plus the singular/plural cases. The rows are: 1-item run, N-item run with position, all done (T = 1, T > 1), some failed, all failed (T = 1, T > 1), and receiving at the head.
