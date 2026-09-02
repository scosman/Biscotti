---
status: draft
---

# Functional Spec: Configurable Model Storage

## 1. Goal

Let the user choose where Biscotti keeps its AI models. Models are multi-GB and
today land unconditionally in `~/Library/Application Support/Biscotti/`. Users
with small internal SSDs want them on an external drive.

Changing the location **moves** the existing models — it never re-downloads
them — and the change is transactional: either the models end up at the new
location and the setting points there, or nothing changes at all.

Because external drives get unplugged, the app must degrade cleanly when the
models are unreachable: recording keeps working, and transcription/summary fail
with a clear, specific message rather than a generic error or a silent
multi-GB re-download.

## 2. Concepts

### 2.1 The model root

A single directory that holds **both** model trees:

| Subtree | Contents | Owner today |
|---|---|---|
| `models/` | WhisperKit (STT) + SpeakerKit (diarization) CoreML models | `Transcription.ModelStorage.downloadBase` |
| `llms/` | GGUF language-model files | `LocalLLM.LocalLLMPaths.defaultModelCacheDir` |

One setting governs both. They always move together.

### 2.2 Default vs. custom location

**Default (unchanged from today):**

```
~/Library/Application Support/Biscotti/
├── models/          ← model root subtree
├── llms/            ← model root subtree
├── Recordings/      ← NOT part of the model root
└── Biscotti.store   ← NOT part of the model root
```

The default model root *is* the app-support directory. Existing installs
therefore need **no migration** — their models are already in the right place.

**Custom:** the user picks a parent folder; Biscotti creates and owns a
`Biscotti Models` folder inside it:

```
/Volumes/BigDisk/AI/            ← the folder the user picked
└── Biscotti Models/            ← Biscotti creates and owns this
    ├── models/
    └── llms/
```

Owning a named subfolder means move, restore, and cleanup only ever touch
directories Biscotti created — never the user's chosen folder itself.

Consequence of keeping the default in place: **Open** on the default location
reveals a folder that also contains `Recordings/` and `Biscotti.store`. Accepted
trade-off; the alternative (a `Models/` subfolder by default) would require
migrating every existing install.

### 2.3 Stored setting

Two new fields on `AppSettings` (SwiftData; defaulted properties, so no
migration stage needed):

- `modelStorageDirectory: String` — the **parent folder the user picked**.
  Empty string = default location. Never stores the `Biscotti Models` suffix;
  that is derived.
- `modelStorageVolumeUUID: String` — the `.volumeUUIDStringKey` of the volume
  that folder was on when it was chosen. Empty for the default location.

The volume UUID exists to make availability checks correct. Checking only that
the path exists is not enough: when a drive is unplugged, `/Volumes/BigDisk` is
gone, and any `createDirectory(withIntermediateDirectories:)` would silently
recreate it **as a plain folder on the boot disk** and re-download gigabytes
into it. A location counts as available only when the path exists *and* the
volume it lives on reports the recorded UUID.

## 3. The Model Storage Location sheet

One sheet, shared by Settings, onboarding, and the error banners.

### 3.1 Layout and copy

- **Title:** `Model Storage Location`
- **Body:** `AI models can be large, control where Biscotti stores them.`
- **Current line:** `Current Directory: <value>` where `<value>` is
  - `Default (Application Support)` for the default location, or
  - the full path to the `Biscotti Models` folder for a custom location.
- **Size line** (muted, below the current line): `4.2 GB of models stored`.
  Computed by summing the two subtrees. While computing, show `Calculating…`.
  If the location is unavailable, omit this line.
- **Button row:**
  - `Open` — reveals the folder in Finder.
  - `Change Location…` — opens an `NSOpenPanel` folder picker.
  - `Restore Default` — shown **only** when a custom location is set.
- **Dismiss:** standard sheet `Done`/close.

(macOS convention: `Change Location…` carries an ellipsis because it opens a
picker. `Open` and `Restore Default` act immediately and do not.)

### 3.2 Unavailable state

When the configured custom location is not available, the sheet shows a caution
row under the current line:

> This location isn't available. Connect "BigDisk" to transcribe or summarize
> meetings.

and `Open` is disabled. `Change Location…` and `Restore Default` stay enabled
(see §5.4).

### 3.3 Busy state

While a move is running, the body is replaced by an indeterminate spinner and
`Moving models…`; all buttons are disabled and the sheet cannot be dismissed.
(Indeterminate is deliberate: `FileManager` copy gives no usable byte-level
progress without hand-rolling the copy loop, and this is a rare operation.)

## 4. Entry points

### 4.1 Settings → AI Enhancements

A new row in the existing AI Enhancements section:

| Title | Subtitle | Control |
|---|---|---|
| `Model Storage Location` | *(none)* | `Manage` button → opens the sheet |

Placed after the `AI Language Model` row. When the configured location is
unavailable, the row shows the standard caution badge treatment already used
elsewhere in Settings.

### 4.2 Onboarding — model download step

Under the model card on the existing "Download Local AI Models" step, a muted
tertiary link:

> `Change storage location`

opening the same sheet. It appears **before** the download starts, so the choice
can be made before gigabytes land in the wrong place. It is deliberately quiet:
the ~95% who accept the default should not have to think about it.

The link is hidden while a download is in flight (a location change is blocked
then anyway — §6.5).

### 4.3 Error banners

The transcription-failure and summary-failure banners for the
"storage unavailable" error carry a `Manage Storage…` action that opens the same
sheet (§7).

## 5. Flows

### 5.1 Change Location — happy path

1. User taps `Change Location…`.
2. `NSOpenPanel` (directories only, no file creation) opens at the current
   location's parent.
3. On selection, validate the destination (§6). Any failure aborts here with an
   alert; nothing changes.
4. If the destination is on a non-internal volume, show the external-drive
   confirmation (§5.3). Cancel aborts.
5. Run the move transaction (§6.1). Sheet enters the busy state.
6. On success: setting and volume UUID are updated, sheet returns to idle with
   the new path and refreshed size.
7. On failure: alert with the reason; setting unchanged; the destination is left
   clean (§6.1).

### 5.2 Restore Default

Identical to §5.1 with the destination fixed to the default location, skipping
the picker and the external-drive confirmation. It performs a **real move** back
— not just a setting flip. On success the emptied `Biscotti Models` folder at the
old custom location is removed; the user's chosen parent folder is left alone.

### 5.3 External-drive confirmation

Shown when the selected volume is not the internal boot volume — removable,
ejectable, *and* network volumes all qualify, since a disconnected SMB share
fails exactly like an unplugged USB drive.

- **Title:** `Use External Drive?`
- **Body:** `If this drive isn't connected, Biscotti can record, but won't be
  able to transcribe or summarize meetings.`
- **Buttons:** `[Cancel] [OK]`

### 5.4 Changing location while the current location is unavailable

The models can't be moved — the source is unreachable. Rather than blocking, the
setting is repointed and the old copy is left behind, with an explicit warning.

- **Title:** `Change Without Moving Models?`
- **Body:** `Biscotti can't reach the current location, so your models can't be
  moved. They'll be left on "BigDisk", and you'll need to download models again
  in the new location. You can delete the old copy yourself at
  /Volumes/BigDisk/AI/Biscotti Models.`
- **Buttons:** `[Cancel] [Change Location]` (or `[Cancel] [Restore Default]`
  when triggered from Restore Default)

After confirming, the setting points at the new location, which has no models.
The app's existing "models not downloaded" states take over — Settings and
onboarding offer the download as normal. Biscotti does **not** track or attempt
to clean up the stranded copy.

## 6. Move transaction

### 6.1 Semantics

The move is all-or-nothing from the user's point of view.

**Same volume** — a `rename(2)` via `FileManager.moveItem`. Atomic, instant, and
needs no free space. Applies to both subtrees.

**Cross volume** — `rename` is impossible, so:

1. Create a staging directory **on the destination volume** (see §6.2).
2. Copy `models/` and `llms/` into the staging directory.
3. Verify the copy (both subtrees present; total byte count matches the source).
4. `rename` the staging directory into its final `Biscotti Models` position —
   same-volume, therefore atomic. This is the commit point.
5. Persist the new `modelStorageDirectory` + `modelStorageVolumeUUID`.
6. Delete the source subtrees.

Failure before step 4 deletes the staging directory and leaves the setting and
the source untouched. Failure at step 6 (source cleanup) still counts as
success: the models are live at the destination; the stale source copy is logged
and left behind rather than failing a move that already worked.

### 6.2 Staging directory

Staging must be on the destination volume, or step 4 stops being atomic. Use
`FileManager.url(for: .itemReplacementDirectory, in: .userDomainMask,
appropriateFor: destinationURL, create: true)`, which is documented to return a
temporary directory on the *same volume as* `appropriateFor` — on an external
drive that is `/Volumes/BigDisk/.TemporaryItems/…`, not `/tmp`.

Some volume formats reject that call. Fallback: a dot-prefixed sibling inside the
chosen parent folder, `.Biscotti Models.incoming-<uuid>`, which is same-volume by
construction. Both paths are cleaned up on failure.

### 6.3 Free-space precheck (fast fail)

Cross-volume moves only — a same-volume rename consumes no space.

Required = total size of `models/` + `llms/`, times 1.1 (10% headroom). Compare
against the destination volume's `volumeAvailableCapacityForImportantUsage`. If
short, abort **before copying a single byte**:

- **Title:** `Not Enough Space`
- **Body:** `Moving your models needs 12.4 GB, but "BigDisk" only has 3.1 GB
  available.`
- **Buttons:** `[OK]`

### 6.4 Destination validation

Checked in order, each with its own alert; all abort before any file operation.

| Condition | Message |
|---|---|
| Not writable | `You don't have permission to write to that folder.` |
| Same as current location | *(no-op — close the picker, change nothing)* |
| Destination is inside the current model root, or the current model root is inside the destination | `Choose a folder outside the current model location.` |
| A `Biscotti Models` folder already exists there and is non-empty | `"Biscotti Models" already exists in that folder. Choose another folder, or remove it first.` |
| Volume is read-only | `That drive is read-only.` |

An existing but **empty** `Biscotti Models` folder is reused, not rejected.

### 6.5 Busy guard

A location change is refused while a transcription job, an AI summary/inference
run, or a model download is in flight:

- **Title:** `Can't Move Models Right Now`
- **Body:** `Wait until transcription, summarization, and model downloads
  finish, then try again.`
- **Buttons:** `[OK]`

The guard is checked when `Change Location…` / `Restore Default` is tapped and
re-checked immediately before the move begins.

### 6.6 After a successful move

Loaded models in the transcriber XPC service and the LLM XPC service still point
at the old path. After the commit the app tears down both XPC connections
(unload + invalidate) so the next job re-resolves against the new root.

## 7. Behavior when models are unreachable

This is the section the "audit" half of the project is about. Expected to be
common once models live on external drives.

### 7.1 Recording is never affected

Recording writes to `<app support>/Biscotti/Recordings/` and touches no model.
It must keep working with the model root unavailable — including the auto-record
and menu-bar paths. This is believed already true; the project verifies it with
tests and a manual-test step rather than assuming.

### 7.2 A distinct, non-transient error

A new error case — model storage unavailable — is raised **before** any download
or model-load attempt, whenever the configured root is a custom location whose
path is missing or whose volume UUID doesn't match.

Message: `Model storage isn't available. Connect "BigDisk" to transcribe this
meeting.` (summary variant: `…to summarize this meeting.`)

It is classified as a distinct failure kind rather than a generic retriable
error, so the UI can offer the right recovery action instead of a bare Retry
that cannot succeed.

**The critical requirement:** in this state Biscotti must never start a
download. Today `InProcessTranscriptionEngine` calls WhisperKit/SpeakerKit with
`download: true` whenever a model isn't loaded, and the Hub layer creates its
directory tree with `withIntermediateDirectories: true` — which would recreate
`/Volumes/BigDisk/` on the boot disk and re-download gigabytes into it. The
availability check must gate this.

### 7.3 Recovery

Manual. Once the drive is connected the user re-runs the job through the existing
Transcribe / Re-transcribe / Regenerate Summary actions. No automatic queue or
volume-mount watcher in this project.

### 7.4 Error banners

Both the transcription-failure banner and the summary-failure banner show the
storage message with two actions:

`[Retry]` `[Manage Storage…]`

`Manage Storage…` opens the sheet (§3). This requires `DesignSystem.Banner` to
gain an optional secondary action; it currently supports one.

> **Open question for review:** `Retry` is shown because it is exactly what the
> user wants after plugging the drive back in — but it does contradict calling
> the error "non-retriable". The alternative is `[Manage Storage…]` alone, with
> retry only via the existing Transcribe/Regenerate actions. Flagging rather
> than deciding silently.

### 7.5 Settings and onboarding

Both show the caution treatment (§3.2, §4.1) when the location is unavailable,
so the state is discoverable without first failing a job.

## 8. Cross-process concerns

`ModelStorage.downloadBase` is a `static let` resolved **independently inside the
`BiscottiTranscriber.xpc` process**, which has no access to the SwiftData store.
The configured root must therefore reach it explicitly — the resolved path is
passed with each request rather than re-derived in the service. The LLM service
already takes an explicit model path and needs no protocol change.

The exact mechanism is an architecture decision (Step 4), but the functional
requirement is fixed: **the app process and the XPC service must never disagree
about where the models are**, including immediately after a location change.

The `Transcription` package's existing default (used by its tests, its CLI
harness, and ManualTestApp) stays as it is today, so nothing outside the app
changes behavior.

## 9. Out of scope

- Separate locations for the STT models and the LLM models.
- Automatically resuming queued transcriptions when a volume reconnects.
- Tracking or cleaning up copies stranded by §5.4.
- Merging two existing model sets when the destination already has models.
- Moving `Recordings/` or `Biscotti.store` — only models are configurable.
- Sandbox/security-scoped bookmarks: the app is non-sandboxed, so plain paths
  work in both the app and the XPC services.

## 10. Testing

Unit/integration (must run without hardware, per repo convention):

- Move transaction: same-volume rename, cross-volume copy-verify-commit, failure
  at each step leaves source + setting intact and destination clean, source
  cleanup failure still reports success.
- Free-space precheck rejects before copying, with the right numbers.
- Destination validation matrix (§6.4), including the nesting cases.
- Availability check: path present but volume UUID mismatched ⇒ unavailable.
- No-download guarantee: with an unavailable root, the transcription path raises
  the storage error and never invokes the downloader (verified with a fake).
- Recording succeeds with the model root unavailable.
- Busy guard blocks during transcription, summary, and download.
- Sheet view-model states: default, custom, unavailable, busy; `Restore Default`
  visibility.

Manual tests (hardware — real external drive):

- Move models to an external drive and back; verify no re-download.
- Eject the drive; record a meeting; confirm recording works and transcription
  fails with the storage message; reconnect; retry succeeds.
- Confirm no folder is created at the stale `/Volumes/...` mount point while the
  drive is disconnected.

Per the repo's manual-test staleness rule, this project touches
`Packages/Transcription` and `Packages/LocalLLM`, so the `tx_*` and `llm_*`
manual-test steps must be marked `not-run` and re-run on hardware.
