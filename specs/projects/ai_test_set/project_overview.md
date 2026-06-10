---
status: complete
---

# A.5 — AI Test Set & Manual Test App Updates

This project is **Project A.5: AI test set**, plus a round of updates to the **Manual Test App**. See `implementation_plan.md` (Stage A → "Project 5 — AI test set") for the roadmap entry.

## Part 1 — AI test set (Project A.5)

Create a new test set for "AI tests." These can be run via CLI just fine, but require downloading gigabytes of models and long, expensive processing (audio transcribe, speaker ID, LLM tests). We want to isolate these (not required on every small commit) but still have them be **automated** tests — not relying on manual runs.

- Create the test set/tag, **excluded by default** when running `make test`.
- Add a new `make` command to run these.
- Add them for **Project 1 (Transcription)**, which should be testable this way. This needs a reference audio file with ground-truth transcription. Tests should be **slightly flexible**: speaker count correct, and Levenshtein distance of the full transcript small but not exact.

### Ground truth

Real audio of **3 distinct human speakers** has been added at `ManualTestApp/Resources/mic.aac` and `ManualTestApp/Resources/system.aac`. We ran the transcriber on these files and **confirmed the output together**. The confirmed transcript (used as ground truth for the Levenshtein-distance test) is:

| # | Text | Speaker |
|---|------|---------|
| 1 | "Hello, this is a test of the system." | A |
| 2 | "Hello, I am person number two." | B |
| 3 | "I am saying something back." | B (same as #2) |
| 4 | "Hi, I'm person number three and you two are banana heads." | C |

So the ground truth is **3 distinct speakers** with the partition `{seg 1} / {seg 2, seg 3} / {seg 4}`. These same files are used for both the AI test and the Manual Test App transcription tests (below).

### Diarization (make it tunable; production unchanged)

Running the current pipeline on this audio produces an accurate transcript **but collapses all four utterances into a single speaker** (`speakerCount = 1`) because diarization runs with SDK defaults (`clusterDistanceThreshold = 0.6`), which over-merges short, distinct utterances. Rather than change production defaults (lowering the threshold globally risks over-splitting real meetings, and we have only one clip), we **expose the cluster-distance threshold as an optional, test-only parameter**. The AI test (and the manual transcribe step) pass a tuned threshold; **production stays on SDK defaults**.

The transcription correctness assertion is **chunk-based**: merge adjacent same-speaker segments into speaker chunks, then require **exactly 3 chunks**, **3 distinct speakers** (A/B/C per the table above, with utterances 2+3 forming one chunk), and **per-chunk Levenshtein ≤ 0.05** against each speaker's script.

## Part 2 — Manual Test App updates

The Manual Test App needs updates too.

**Decouple transcription from audio capture.** Today the transcription tests use audio files produced by the audio-capture part of the app (the audio-recorder). That makes them a lot of work — you have to get 2 people together and record audio. And static assertions like "ensure 2 speakers" don't make sense for an app with dynamic audio (a real recording might be just 1 person). Update the transcription tests to use the static `Resources/mic.aac` / `system.aac` files instead, and **decouple the transcription tests from the audio-capture portion of the app completely**.

**Expand the audio test cases.** Related:

- **General:** swap mentions of **FaceTime** for **Google Meet**. Why? It's easy to create an "instant meeting" with 1 participant for testing, whereas FaceTime audio waits for a real call.
- **Cases to add (if missing):**
  - Start capture with Google Meet running, then close Google Meet after a few seconds. Verify mic worked both **before and after**.
  - Start capture **without** Google Meet running, then start Google Meet after a few seconds. Verify mic worked both **before and after**.
  - Connect and disconnect AirPods: confirm mic audio transfers computer → AirPods → back (you can hear the mic change).
  - **Mega experiment:** start capture, start a Google meeting, start the Music app (saying "starting music now"), put in AirPods, take out AirPods, stop Google Meet, stop capture. Voice should work in all modes. System audio should start at the exact right time, timed to the mic.
- **Fix unclear instructions:**
  - The "kill -9 / Activity Monitor" instructions don't give a process name. Be better — say exactly which process to kill.
  - "Transcribe with custom vocab bias" needs a better explanation. As written, it's unclear what vocab is being applied, what to test, and how to test it.
