# Reference Quality Check (Run 1)

WER and the LLM judgement both lean on the reference transcript (Microsoft MAI-Transcribe 2 via OpenRouter). We picked it for its published WER. This check asks a different question: on *our* meetings, is it actually the best of the three, and is it pleasant to read?

## Method

- **Sample:** 4 windows of 90 s per meeting, at 20 / 40 / 60 / 80 % of the meeting duration. 64 windows, about 96 min of the 13.4 h of audio (about 12 %).
- **Blind:** for each window, the Apple, Whisper and reference text was cut by timestamp, speaker labels and line breaks were removed, and the three texts were shuffled as X / Y / Z. A key file maps labels back to engines after judging.
- **Judges:** LLM agents (Claude Opus 5.5), 8 windows per agent, one judge per window.
- **Accuracy pass (64 windows):** rank the three from most to least faithful; estimate clear content errors per transcript; give the winner's margin. Polish is not rewarded; dropped real content is penalized. Prompt: `experiments/STTLab/scripts/judge/prompts/blind_accuracy.md`.
- **Style pass (16 windows, one per meeting):** rate punctuation, capitalization, sentence segmentation and readability (1–5), and pick the transcript you would rather read. Accuracy is ignored here. Prompt: `experiments/STTLab/scripts/judge/prompts/blind_style.md`.
- **Limits:** the judges cannot hear audio. They judge plausibility, coherence and agreement between the three texts. Style cues (filler density, punctuation density) can partly reveal which engine is which, so the test is not fully blind.

## Accuracy Results

| Engine | Ranked 1st | Ranked last | Mean rank | Clear errors / window |
|---|---|---|---|---|
| Reference (MAI-Transcribe 2) | **49** | **0** | **1.23** | **0.70** |
| Whisper large-v3-turbo | 15 | 3 | 1.81 | 1.84 |
| Apple SpeechTranscriber | 0 | 61 | 2.95 | 4.22 |

- The reference was never ranked last. When it won, the margin was "clear" in 32 of 49 windows.
- Whisper won 15 windows (5 clear, 10 slight). In all 5 clear Whisper wins, the reference was second.
- **Exception: m13** (a guided meditation recording with long silences). Whisper ranked first in all 4 windows. The analyzer also flags two 30–45 s stretches where the reference dropped speech in m13. Treat m13 WER and LLM decisions as less reliable.

## Style Results

| Engine | Punctuation | Capitalization | Segmentation | Readability | Preferred |
|---|---|---|---|---|---|
| Reference | **3.94** | **4.38** | **3.69** | **3.69** | 8 |
| Whisper | 3.31 | 3.44 | 3.38 | 3.25 | 8 |
| Apple | 3.31 | 3.38 | 3.12 | 2.88 | 0 |

- **Reference:** best punctuation and casing (acronyms and product names cased correctly). Keeps fillers and stutters (sometimes as dashes), which some judges found less smooth.
- **Whisper:** removes most fillers, which reads smoothly — tied with the reference for "preferred". But in 4 of 16 windows it falls into long **all-lowercase, unpunctuated stretches** mid-window. This is worth checking in production (we did not check whether `TranscriptSanitizer` or segment building hides it).
- **Apple:** punctuation density is close to the reference (see `report_stats.md`, Text Quality), but it was never preferred. Garbled technical terms, odd sentence breaks and mixed number formats make it the hardest to read.

## Conclusion

The reference is the right reference. On this data it is clearly the most accurate of the three (about 2.5x fewer clear errors than Whisper and 6x fewer than Apple), and the most readable. WER against it is a fair measure, with the m13 exception above.

## Re-run

See `how_to_retest.md`, section "Optional: reference quality check". Scripts: `refcheck_build.py` (builds windows and key), `refcheck_summarize.py` (unblinds and prints the tables above).
