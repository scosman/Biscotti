---
status: complete
---

# Functional Spec: Apple STT Validation

## 1. Purpose

Produce the evidence to decide whether Apple's `SpeechTranscriber` can be Biscotti's default STT engine (with WhisperKit as the alternative). The output is a **report, not a decision**. The choice is a multi-variable trade-off that the user makes from the report.

Background: `specs/research/stt-engine-swap/summary.md` and `specs/research/stt-engine-swap/apple-speech-apis/summary.md`.

The experiment compares three transcripts of the same real meetings:

| Engine | Role | Runs on |
|---|---|---|
| **Apple SpeechTranscriber** | Candidate | The macOS 27 Mac ("runner Mac") |
| **WhisperKit** (production pipeline: `openai_whisper-large-v3-v20240930_626MB`, merged audio) | Incumbent | The macOS 15 Mac ("home Mac") |
| **MAI-Transcribe 2** (OpenRouter, server-side) | SOTA reference (see §3.5) | Called from the home Mac |

SpeakerKit diarization runs on the home Mac. Both local engines' word timings are aligned to the same SpeakerKit timeline during analysis.

## 2. Workflow

Three tools, one round trip:

```
HOME MAC (macOS 15)                    RUNNER MAC (macOS 27)
───────────────────                    ─────────────────────
1. prep  ── select 10 meetings ──┐
         ── user reviews list    │
         ── build bundle ────────┼── AirDrop ──►  2. runner app
         ── Whisper + SpeakerKit │                   ── Apple SpeechTranscriber
         ── MAI-Transcribe 2     │                   ── save everything
                                 │                         │
3. analyze ◄─────────────────────┴── AirDrop ◄── results folder
         ── metrics + report
```

- **The runner stays simple and robust.** It runs only the Apple API and saves all raw data it can get. No analysis, no network, no model downloads beyond Apple's own assets.
- **All heavy and changeable work happens on the home Mac.** Analysis must be re-runnable on saved data, so we can change the analysis without re-running engines or re-calling the cloud.

## 3. Tool 1 — `prep` (home Mac)

### 3.1 Meeting selection

- Reads the local Biscotti store (recordings + existing transcripts).
- Proposes **10 meetings**: **5 of about 30 minutes** (25–40 min) and **5 of about 1 hour** (50–75 min).
- Eligibility: both `mic.aac` and `system.aac` exist and are readable; an existing transcript exists with **at least 2 speakers**.
- Among eligible meetings, prefer variety: different dates, different speaker counts, a range of transcript word density (words per minute — a proxy for crosstalk/noise).
- If too few meetings qualify for a length bucket, fill from the nearest bucket and say so. If fewer than 10 qualify in total, propose what exists and say so.
- Prints the proposal (date, title, duration, speaker count, word count) and writes it to an editable selection file.

### 3.2 User review (required)

- The user reviews the proposal for privacy and content, and can remove or swap meetings by editing the selection file.
- **No audio leaves the machine and no bundle is built until the user confirms the selection.** Confirmation is an explicit step (a separate command or flag), not a default.

### 3.3 Bundle build

For each confirmed meeting, prep writes into a new bundle folder:

- The original `mic.aac` and `system.aac`.
- **One merged mono WAV**, produced by the production `AudioMerger` at the sample rate the production pipeline uses. **All three engines and SpeakerKit transcribe this exact file**, so every engine sees identical input.
- Metadata: anonymized meeting id, duration, speaker count and language of the existing transcript, and the **Apple locale** to use (default `en_US`; editable per meeting in the selection file).

Plus a bundle manifest (bundle version, creation time, list of meetings, prep tool version).

### 3.4 Home-Mac engine runs

Run per meeting on the merged WAV, saving **raw outputs** (not only processed ones):

- **WhisperKit**, same settings as production (model, word timestamps on, language handling as production). Save segments, words with start/end/probability, detected language, wall time, audio duration, peak memory of the process (best effort), and the hardware/OS info.
- **SpeakerKit**, same settings as production. Save the full diarization result (speaker segments, and anything else the result exposes) so analysis can align any engine's words to it.
- **The reference model** (§3.5) through OpenRouter's `/api/v1/audio/transcriptions` endpoint, with `response_format: "verbose_json"` and `timestamp_granularities: ["word"]`. Save the raw response JSON per request.
  - The API key comes from the environment (e.g. `OPENROUTER_API_KEY`). It is never written to the bundle, results or repo.
  - Long audio is split into chunks if the endpoint's size/duration limit requires it. Chunk boundaries fall at silences where possible. The chunk plan (offsets) is saved with the responses, so analysis can rebuild one timeline.
  - Zero data retention: requests use OpenRouter's ZDR enforcement if it is available for this model. The user verifies the model's retention policy before the first upload (see §9).

Each step is **resumable and cached**: re-running prep skips work that already has a saved output. A failure in one meeting or one engine is logged and does not stop the others.

### 3.5 Reference model and fallback

- **Reference:** MAI-Transcribe 2 (`microsoft/mai-transcribe-2`, released 2026-09-03). OpenRouter documents segment and **word-level** timestamps for it.
- Not used: Voxtral Transcribe 3 (released 2026-10-20). It has ZDR endpoints, but at launch Small Transcribe 3 returns no timestamps and Mini Transcribe 3 returns segment timestamps only. Word timestamps are required for §5.4.
- The reference model is a prep setting, not hard-coded. The model id and the routed provider are saved with every response, and the report names the reference model used.
- The whole bundle uses **one** reference model. If the reference fails for some meetings after retries and chunking, the user can switch the setting to another model and re-run all meetings, so every meeting is scored against the same reference.
- Word-level timestamps are requested from whichever model is used. If the model returns only coarser timestamps, timing metrics against the reference are marked unavailable (§7).

The bundle that goes to the runner Mac contains only what the runner needs (WAVs, metadata, manifest). Whisper, SpeakerKit and reference outputs stay on the home Mac.

## 4. Tool 2 — runner app (runner Mac, macOS 27)

### 4.1 Use

1. The user opens the app and selects the bundle folder (received through AirDrop).
2. The app shows the meetings and their locales, and a **Run** button.
3. The app runs Apple `SpeechTranscriber` on each meeting's merged WAV, one at a time, and shows progress (meeting n of 10, elapsed time).
4. When done, the app writes a **results folder** next to the bundle (or to a user-chosen location) and offers to reveal it in Finder for AirDrop back.

### 4.2 What it runs

- `SpeechTranscriber` (never `DictationTranscriber`), batch file input, final results only, with every available per-run attribute turned on (time ranges, confidence, alternatives if available).
- The locale from the meeting metadata. If Apple does not support that locale, the meeting is marked `unsupported_locale` and skipped.
- If Apple's assets for the locale are not installed, the app installs them through the system asset API and logs that a download happened.

### 4.3 What it saves (per meeting)

Save everything the API returns, in a lossless form, so analysis never needs a re-run:

- Every result in order, with its text, time range, finalization info, and every attributed run (run text, `audioTimeRange`, confidence, any other attribute present). Alternatives, if returned.
- Wall time (start, end, total), audio duration.
- Our process's peak memory (best effort). Apple's model runs in a system process; if the app can sample that process's memory, it saves it, otherwise it records "unavailable".
- Any error, with its full description.

Per run: OS version and build, chip, RAM, app version, start/end times, the locale list Apple reports as supported, and a log file.

### 4.4 Robustness

- One meeting's failure does not stop the run. The failure is recorded and the next meeting starts.
- Results for each meeting are written to disk as soon as that meeting finishes, so a crash or quit keeps completed work. Re-running skips meetings that already have results (with an option to force a re-run).
- The app needs no network access, no API keys and no permissions beyond file access to the chosen folders.
- Distribution: built on the home Mac as an ad-hoc-signed `.app`, copied to the runner Mac. It must open there through the standard "Open Anyway" flow. A short README in the bundle tells the runner-Mac user what to do.

## 5. Tool 3 — `analyze` (home Mac)

Inputs: the prep outputs (Whisper, SpeakerKit, reference) and the returned results folder. Output: a report folder with a readable report (Markdown or HTML) plus machine-readable metrics JSON. Re-runnable at any time on saved data.

All text comparisons use one normalization: lowercase, strip punctuation, normalize whitespace, and expand/normalize numbers and common contractions consistently across engines. Punctuation and casing are measured separately (§5.3).

### 5.1 Speed

- Per engine per meeting: wall time and real-time factor (audio duration / wall time).
- Each figure is shown with the machine it ran on. **Apple and Whisper run on different Macs**, so the report labels the cross-engine speed comparison as cross-machine and shows chip/RAM for each.
- Speed is informational, not a focus: public benchmarks already cover it. The experiment does not add same-machine timing.

### 5.2 Accuracy

- WER of Apple and of Whisper against the reference, per meeting and overall (substitutions, deletions, insertions shown separately).
- WER between Apple and Whisper (how much they disagree).
- **Disagreement tie-break:** align all three transcripts. For each region where Apple and Whisper disagree, classify it as: Apple matches the reference, Whisper matches the reference, both match the reference partly, or neither matches. Report counts per meeting and overall.
- A sample of disagreement regions (with timestamps and the three texts side by side) for the user to read. The sample includes the largest regions and a random set.
- Flag any meeting where one engine's WER against the reference is more than 2x the other's, or where an engine drops a long stretch of audio (a gap of 30 s or more with no words while the other two engines have words).

### 5.3 Text quality

- Punctuation density (marks per 100 words) and sentence count per engine.
- Casing: share of sentence starts capitalized; share of words capitalized mid-sentence.
- Filler words ("um", "uh", etc.): counts per engine, to show whether an engine drops or keeps them.

### 5.4 Word timing

- Match words across engines (by aligned text).
- For matched words: distribution of start-time and end-time differences for Apple vs Whisper, Apple vs reference, and Whisper vs reference (median, 90th percentile, max).
- Apple run granularity: share of runs that are whole words, sub-word pieces, punctuation-only, or multi-word.
- Apple timing anomalies: zero-length runs, overlapping runs, runs out of order, runs outside the audio duration.

### 5.5 Speaker alignment

- Group each engine's output into words (Apple runs are grouped into words; Whisper and the reference already have words).
- Align each engine's words to the **same** SpeakerKit diarization, using the production alignment path (SpeakerKit `addSpeakerInfo`, `.subsegment` strategy, through the WhisperKit-type bridge described in the research).
- Report:
  - Speaker agreement between Apple-aligned and Whisper-aligned output: share of audio time (and of matched words) assigned to the same speaker.
  - Segment count and segment length distribution per engine after alignment.
  - Number of speaker changes per engine.
  - A sample of places where the two engines' speaker labels differ.

### 5.6 Other

- Stability: per engine, meetings completed vs failed, with errors.
- Memory: whatever was measurable, labelled with what it covers (our process only, or the system speech process too).
- Locale coverage: meetings skipped for unsupported locale.

### 5.7 Report layout

1. Run summary: machines, OS versions, meetings, what completed.
2. One summary table: per engine — overall WER vs reference, tie-break wins, RTF, timing error median, speaker agreement.
3. Per-meeting table with the same columns plus flags.
4. Sections for §5.1–5.6 with details and samples.
5. Caveats: cross-machine speed, the reference model as an imperfect reference, normalization rules, anything that failed.

No pass/fail verdict appears in the report.

## 6. Scope

### In scope

- The three tools above, as a new experiment under `experiments/`.
- A `NOTES.md` in the experiment folder that records how to run it and, after the run, the findings (per the repo convention for experiments).

### Out of scope (deferred)

- Any change to the Biscotti app or its packages. App integration is designed only if the user decides to proceed after reading the report.
- Energy measurement (the work is not CPU-bound, so per-process CPU figures would mislead).
- Apple asset state and model load time measurements (load time is small against a 1-hour meeting). The runner only logs whether it had to download assets.
- Running Apple inside an XPC service, and the permission-prompt check.
- Parakeet / FluidAudio and any other engine.
- Non-English evaluation as a goal. A meeting in another language is allowed if its locale is set, but the selection does not seek them out.

## 7. Edge Cases and Errors

| Case | Behaviour |
|---|---|
| Fewer than 10 eligible meetings | prep proposes what exists and states the shortfall |
| Recording missing one track | Not eligible |
| OpenRouter call fails (network, rate limit, 5xx) | Retry with backoff; after the retry limit, record the failure for that meeting/chunk and continue. Re-running prep retries only the failed items |
| OpenRouter rejects the file size | Use smaller chunks |
| Apple locale unsupported | Runner marks the meeting `unsupported_locale` and continues |
| Apple returns no results for a meeting | Saved as an empty result with the duration; analysis flags it |
| Runner app quits or crashes mid-run | Completed meetings are already on disk; re-run resumes |
| Bundle version does not match the runner's expected version | Runner refuses to start and shows both versions |
| Results folder does not match the bundle (different meeting ids) | analyze refuses and lists the mismatch |
| Reference response lacks word timestamps | Accuracy metrics still run; timing metrics against the reference are marked unavailable |

## 8. Constraints

- Runner: macOS 27, Apple Silicon. Home tools: macOS 15+, Apple Silicon.
- The runner app has no network dependency.
- Secrets: the OpenRouter key is read from the environment on the home Mac only.
- Data: the bundle and the results contain meeting audio or meeting text. They live outside the repo (or in a git-ignored folder) and are never committed. Only the experiment code, `NOTES.md` and (optionally) a sanitized summary of findings are committed.
- Cost: MAI-Transcribe 2 is $0.10 per audio hour, so 10 meetings cost under $1. Re-runs use cached responses.

## 9. Open Items for the User

- **Reference model data retention.** OpenRouter's MAI-Transcribe 2 page does not state a retention or training policy. Before the first upload, confirm that it meets your zero-data-retention requirement (for example, through OpenRouter's account-level ZDR setting). prep will not upload until you confirm the meeting selection.
- **Consent.** You review and accept the selected meetings for cloud upload (§3.2).
