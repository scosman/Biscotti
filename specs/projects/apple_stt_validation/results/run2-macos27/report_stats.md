# STTLab Report

## Run Summary

- **Bundle ID:** 5CE91FC4-1F4D-4628-9BAD-FC1DBE2B1AD9
- **Home Mac:** Apple M4 Pro, 48 GB RAM, Version 15.6.1 (Build 24G90)
- **Runner Mac:** Apple M2, 16 GB RAM, Version 27.0.1 (Build 26A434)
- **Reference model:** microsoft/mai-transcribe-2
- **ZDR:** yes
- **Reference total cost:** $1.34
- **Meetings:** 16

| Meeting | Duration | Speakers | Apple | Whisper | Reference |
|---|---|---|---|---|---|
| m01 | 32:00 | 2 | completed | completed | completed |
| m02 | 32:31 | 8 | completed | completed | completed |
| m03 | 34:10 | 3 | completed | completed | completed |
| m04 | 31:21 | 6 | completed | completed | completed |
| m05 | 33:25 | 4 | completed | completed | completed |
| m06 | 31:16 | 2 | completed | completed | completed |
| m07 | 38:38 | 4 | completed | completed | completed |
| m08 | 29:00 | 8 | completed | completed | completed |
| m09 | 154:13 | 10 | completed | completed | completed |
| m10 | 65:40 | 4 | completed | completed | completed |
| m11 | 51:21 | 3 | completed | completed | completed |
| m12 | 54:57 | 4 | completed | completed | completed |
| m13 | 50:50 | 2 | completed | completed | completed |
| m14 | 54:58 | 3 | completed | completed | completed |
| m15 | 59:08 | 2 | completed | completed | completed |
| m16 | 51:07 | 4 | completed | completed | completed |

## Summary

| Metric | Apple | Whisper |
|---|---|---|
| WER vs reference | 9.9% | 9.3% |
| LLM wins (high) | 62 | 142 |
| LLM wins (med) | 517 | 1159 |
| LLM wins (low) | 2187 | 2192 |
| LLM wins (total) | 2766 | 3493 |
| Median RTF | 67.64x (runner) | 15.25x (home) |
| Median |ΔStart| A-W | 0.080s | — |
| Median |ΔStart| vs ref | 0.100s | 0.100s |
| Speaker agreement (time) | 98.0% | — |

## Per-Meeting Results

| Meeting | Duration | Speakers | WER A | WER W | A-W disagree | A wins | W wins | Both ok | Unknown | A high loss | W high loss | Median |ΔStart| A-W | Speaker agree | Flags |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| m01 | 32:00 | 2 | 11.9% | 11.7% | 12.7% | 128 | 153 | 8 | 12 | 9 | 9 | 0.080s | 94.1% | — |
| m02 | 32:31 | 8 | 7.8% | 6.8% | 8.6% | 119 | 150 | 18 | 13 | 7 | 1 | 0.080s | 98.2% | — |
| m03 | 34:10 | 3 | 7.6% | 7.5% | 9.3% | 125 | 193 | 87 | 7 | 11 | 1 | 0.080s | 98.3% | — |
| m04 | 31:21 | 6 | 6.6% | 5.7% | 7.2% | 92 | 153 | 32 | 13 | 14 | 3 | 0.060s | 99.8% | — |
| m05 | 33:25 | 4 | 12.9% | 12.7% | 15.8% | 154 | 160 | 17 | 13 | 8 | 2 | 0.080s | 98.0% | — |
| m06 | 31:16 | 2 | 7.9% | 6.9% | 8.7% | 117 | 176 | 22 | 6 | 23 | 4 | 0.080s | 99.7% | — |
| m07 | 38:38 | 4 | 10.6% | 9.4% | 10.3% | 135 | 200 | 63 | 23 | 4 | 7 | 0.080s | 96.7% | — |
| m08 | 29:00 | 8 | 8.7% | 7.8% | 9.8% | 103 | 170 | 29 | 10 | 8 | 2 | 0.080s | 98.8% | — |
| m09 | 154:13 | 10 | 13.1% | 14.3% | 16.1% | 433 | 386 | 87 | 39 | 10 | 13 | 0.080s | 98.7% | 11 dropped-stretch flag(s) |
| m10 | 65:40 | 4 | 11.7% | 10.2% | 11.8% | 246 | 383 | 66 | 25 | 5 | 1 | 0.080s | 97.5% | — |
| m11 | 51:21 | 3 | 11.6% | 10.4% | 13.8% | 188 | 281 | 25 | 17 | 6 | 6 | 0.080s | 95.2% | — |
| m12 | 54:57 | 4 | 8.7% | 8.0% | 9.0% | 230 | 288 | 42 | 27 | 8 | 3 | 0.080s | 98.9% | — |
| m13 | 50:50 | 2 | 6.1% | 4.8% | 6.2% | 29 | 64 | 0 | 1 | 0 | 1 | 0.080s | 100.0% | 3 dropped-stretch flag(s) |
| m14 | 54:58 | 3 | 6.7% | 6.2% | 7.5% | 228 | 241 | 27 | 20 | 12 | 6 | 0.060s | 98.8% | — |
| m15 | 59:08 | 2 | 11.0% | 11.3% | 11.6% | 302 | 293 | 30 | 29 | 6 | 2 | 0.080s | 97.2% | — |
| m16 | 51:07 | 4 | 12.6% | 10.6% | 13.4% | 137 | 202 | 32 | 32 | 11 | 1 | 0.080s | 97.5% | — |

## Speed

> Apple and Whisper run on different Macs. Speed comparisons are cross-machine.

| Meeting | Apple RTF | Apple machine | Whisper RTF | Whisper machine |
|---|---|---|---|---|
| m01 | 75.04x | Apple M2 | 17.53x | Apple M4 Pro |
| m02 | 61.95x | Apple M2 | 15.25x | Apple M4 Pro |
| m03 | 45.16x | Apple M2 | 13.81x | Apple M4 Pro |
| m04 | 56.96x | Apple M2 | 14.29x | Apple M4 Pro |
| m05 | 74.89x | Apple M2 | 16.42x | Apple M4 Pro |
| m06 | 54.73x | Apple M2 | 15.14x | Apple M4 Pro |
| m07 | 62.03x | Apple M2 | 15.23x | Apple M4 Pro |
| m08 | 53.29x | Apple M2 | 14.53x | Apple M4 Pro |
| m09 | 104.22x | Apple M2 | 24.05x | Apple M4 Pro |
| m10 | 70.33x | Apple M2 | 15.85x | Apple M4 Pro |
| m11 | 75.48x | Apple M2 | 16.81x | Apple M4 Pro |
| m12 | 57.19x | Apple M2 | 14.01x | Apple M4 Pro |
| m13 | 169.04x | Apple M2 | 29.54x | Apple M4 Pro |
| m14 | 53.45x | Apple M2 | 13.94x | Apple M4 Pro |
| m15 | 67.64x | Apple M2 | 15.09x | Apple M4 Pro |
| m16 | 88.57x | Apple M2 | 18.33x | Apple M4 Pro |

## Accuracy

### WER Breakdown (pooled)

| Pair | Ref words | S | D | I | WER |
|---|---|---|---|---|---|
| Apple vs Reference | 126910 | 5686 | 5313 | 1577 | 9.9% |
| Whisper vs Reference | 126910 | 3237 | 7442 | 1161 | 9.3% |
| Apple vs Whisper (disagreement) | 120629 | 5605 | 2517 | 5062 | 10.9% |

### LLM Judgement

Meetings judged: 16 / 16

| Decision | Low | Med | High | Total |
|---|---|---|---|---|
| Apple wins | 2187 | 517 | 62 | 2766 |
| Whisper wins | 2192 | 1159 | 142 | 3493 |
| Both acceptable | — | — | — | 585 |
| Unknown | — | — | — | 287 |

### Mistakes That Matter

*Removed: this section quotes meeting speech.*

### Flags

*Removed: this section quotes meeting speech.*

## Text Quality

| Metric | Apple | Whisper | Reference |
|---|---|---|---|
| Punct / 100 words | 20.56 | 14.06 | 21.43 |
| Sentence start cap % | 96.15 | 97.63 | 97.40 |
| Mid-sentence cap % | 2.08 | 1.77 | 2.29 |
| Fillers / 1000 words | 11.37 | 4.29 | 14.07 |

## Word Timing

### Apple vs Whisper

| Stat | ΔStart | ΔEnd |
|---|---|---|
| Pairs | 107588 | 107588 |
| Median |Δ| | 0.080s | 0.080s |
| P90 |Δ| | 0.240s | 0.200s |
| Max |Δ| | 328.079s | 329.360s |
| Median signed | 0.020s | 0.040s |

### Apple vs Reference

| Stat | ΔStart | ΔEnd |
|---|---|---|
| Pairs | 99751 | 99751 |
| Median |Δ| | 0.100s | 0.061s |
| P90 |Δ| | 0.300s | 0.180s |
| Max |Δ| | 241.500s | 241.760s |
| Median signed | -0.100s | -0.020s |

### Whisper vs Reference

| Stat | ΔStart | ΔEnd |
|---|---|---|
| Pairs | 100187 | 100187 |
| Median |Δ| | 0.100s | 0.060s |
| P90 |Δ| | 0.320s | 0.161s |
| Max |Δ| | 43.680s | 43.661s |
| Median signed | -0.100s | -0.060s |

### Apple Run Granularity

Total runs: 119054

| Class | Count | Share |
|---|---|---|
| punctuationOnly | 3 | 0.0% |
| wholeWord | 119051 | 100.0% |
| subWord | 0 | 0.0% |
| multiWord | 0 | 0.0% |
| whitespace | 0 | 0.0% |

## Speaker Alignment

### Apple vs Whisper Agreement

- Time agreement: 98.0%
- Word agreement: 98.2%

### Apple vs Reference Agreement

> Uses the same diarization as A-W; only the bridged engine differs.

- Time agreement: 99.3%
- Word agreement: 99.5%

### Whisper vs Reference Agreement

> Uses the same diarization as A-W; only the bridged engine differs.

- Time agreement: 97.9%
- Word agreement: 98.2%

### Segment Statistics

| Metric | Apple | Whisper |
|---|---|---|
| Total segments | 38455 | 15640 |
| Total turns | 2623 | 2267 |
| Total speaker changes | 2607 | 2251 |

### Speaker Disagreement Sample (top 20)

*Removed: this section quotes meeting speech.*

## Other

### Stability

| Engine | Completed | Failed |
|---|---|---|
| Apple | 16 | 0 |
| Whisper | 16 | 0 |
| Reference | 16 | 0 |

### Memory

| Meeting | Engine | Process peak | Lifetime peak | System processes |
|---|---|---|---|---|
| m01 | Apple | 55 MB | 56 MB | com.apple.siri.embeddedspeech (pid 1391): 28 MB; corespeechd (pid 1034): 11 MB; localspeechrecognition (pid 1161): 6 MB; localspeechrecognition (pid 1047): 6 MB; localspeechrecognition (pid 2085): 6 MB; localspeechrecognition (pid 1098): 6 MB; localspeechrecognition (pid 2088): 46 MB; speechmaintenanced (pid 1049): 4 MB |
| m01 | Whisper | 377 MB | 382 MB | n/a |
| m01 | Diarization | 957 MB | 1040 MB | n/a |
| m02 | Apple | 95 MB | 114 MB | com.apple.siri.embeddedspeech (pid 1391): 10 MB; corespeechd (pid 1034): 11 MB; localspeechrecognition (pid 1047): 6 MB; localspeechrecognition (pid 1161): 6 MB; localspeechrecognition (pid 2088): 50 MB; localspeechrecognition (pid 1098): 6 MB; speechmaintenanced (pid 1049): 4 MB |
| m02 | Whisper | 381 MB | 401 MB | n/a |
| m02 | Diarization | 865 MB | 1040 MB | n/a |
| m03 | Apple | 60 MB | 124 MB | com.apple.siri.embeddedspeech (pid 1391): 10 MB; corespeechd (pid 1034): 12 MB; localspeechrecognition (pid 1161): 6 MB; localspeechrecognition (pid 2088): 68 MB; localspeechrecognition (pid 1047): 6 MB; localspeechrecognition (pid 1098): 6 MB; speechmaintenanced (pid 1049): 4 MB |
| m03 | Whisper | 378 MB | 455 MB | n/a |
| m03 | Diarization | 822 MB | 1040 MB | n/a |
| m04 | Apple | 157 MB | 157 MB | com.apple.siri.embeddedspeech (pid 1391): 10 MB; corespeechd (pid 1034): 12 MB; localspeechrecognition (pid 1047): 6 MB; localspeechrecognition (pid 1098): 6 MB; localspeechrecognition (pid 2088): 45 MB; localspeechrecognition (pid 1161): 6 MB; speechmaintenanced (pid 1049): 4 MB |
| m04 | Whisper | 301 MB | 455 MB | n/a |
| m04 | Diarization | 800 MB | 1040 MB | n/a |
| m05 | Apple | 131 MB | 157 MB | com.apple.siri.embeddedspeech (pid 1391): 10 MB; corespeechd (pid 1034): 11 MB; localspeechrecognition (pid 1047): 6 MB; localspeechrecognition (pid 2088): 38 MB; localspeechrecognition (pid 1098): 6 MB; localspeechrecognition (pid 1161): 6 MB; speechmaintenanced (pid 1049): 4 MB |
| m05 | Whisper | 413 MB | 455 MB | n/a |
| m05 | Diarization | 750 MB | 1040 MB | n/a |
| m06 | Apple | 114 MB | 157 MB | com.apple.siri.embeddedspeech (pid 1391): 10 MB; corespeechd (pid 1034): 11 MB; localspeechrecognition (pid 1047): 6 MB; localspeechrecognition (pid 1098): 6 MB; localspeechrecognition (pid 1161): 6 MB; localspeechrecognition (pid 2088): 60 MB; speechmaintenanced (pid 1049): 4 MB |
| m06 | Whisper | 349 MB | 455 MB | n/a |
| m06 | Diarization | 716 MB | 1040 MB | n/a |
| m07 | Apple | 103 MB | 157 MB | com.apple.siri.embeddedspeech (pid 1391): 10 MB; corespeechd (pid 1034): 11 MB; localspeechrecognition (pid 2088): 44 MB; localspeechrecognition (pid 1098): 6 MB; localspeechrecognition (pid 1047): 6 MB; localspeechrecognition (pid 1161): 6 MB; speechmaintenanced (pid 1049): 4 MB |
| m07 | Whisper | 315 MB | 455 MB | n/a |
| m07 | Diarization | 837 MB | 1040 MB | n/a |
| m08 | Apple | 129 MB | 157 MB | com.apple.siri.embeddedspeech (pid 1391): 10 MB; corespeechd (pid 1034): 11 MB; localspeechrecognition (pid 1161): 6 MB; localspeechrecognition (pid 2088): 74 MB; localspeechrecognition (pid 1047): 6 MB; localspeechrecognition (pid 1098): 6 MB; speechmaintenanced (pid 1049): 4 MB |
| m08 | Whisper | 298 MB | 455 MB | n/a |
| m08 | Diarization | 775 MB | 1040 MB | n/a |
| m09 | Apple | 112 MB | 157 MB | com.apple.siri.embeddedspeech (pid 1391): 10 MB; corespeechd (pid 1034): 11 MB; localspeechrecognition (pid 1047): 6 MB; localspeechrecognition (pid 1098): 6 MB; localspeechrecognition (pid 1161): 6 MB; localspeechrecognition (pid 2088): 49 MB; speechmaintenanced (pid 1049): 4 MB |
| m09 | Whisper | 868 MB | 912 MB | n/a |
| m09 | Diarization | 2405 MB | 2424 MB | n/a |
| m10 | Apple | 147 MB | 199 MB | com.apple.siri.embeddedspeech (pid 1391): 10 MB; corespeechd (pid 1034): 11 MB; localspeechrecognition (pid 1161): 6 MB; localspeechrecognition (pid 2088): 41 MB; localspeechrecognition (pid 1047): 6 MB; localspeechrecognition (pid 1098): 6 MB; speechmaintenanced (pid 1049): 4 MB |
| m10 | Whisper | 539 MB | 912 MB | n/a |
| m10 | Diarization | 1073 MB | 2424 MB | n/a |
| m11 | Apple | 171 MB | 199 MB | com.apple.siri.embeddedspeech (pid 1391): 10 MB; corespeechd (pid 1034): 11 MB; localspeechrecognition (pid 1161): 6 MB; localspeechrecognition (pid 1047): 6 MB; localspeechrecognition (pid 1098): 6 MB; localspeechrecognition (pid 2088): 41 MB; speechmaintenanced (pid 1049): 4 MB |
| m11 | Whisper | 348 MB | 912 MB | n/a |
| m11 | Diarization | 943 MB | 2424 MB | n/a |
| m12 | Apple | 137 MB | 199 MB | com.apple.siri.embeddedspeech (pid 1391): 10 MB; corespeechd (pid 1034): 11 MB; localspeechrecognition (pid 1047): 6 MB; localspeechrecognition (pid 1098): 6 MB; localspeechrecognition (pid 2088): 54 MB; localspeechrecognition (pid 1161): 6 MB; speechmaintenanced (pid 1049): 4 MB |
| m12 | Whisper | 349 MB | 912 MB | n/a |
| m12 | Diarization | 856 MB | 2424 MB | n/a |
| m13 | Apple | 165 MB | 199 MB | com.apple.siri.embeddedspeech (pid 1391): 10 MB; corespeechd (pid 1034): 11 MB; localspeechrecognition (pid 1098): 6 MB; localspeechrecognition (pid 2088): 34 MB; localspeechrecognition (pid 1047): 6 MB; localspeechrecognition (pid 1161): 6 MB; speechmaintenanced (pid 1049): 4 MB |
| m13 | Whisper | 442 MB | 912 MB | n/a |
| m13 | Diarization | 818 MB | 2424 MB | n/a |
| m14 | Apple | 195 MB | 199 MB | com.apple.siri.embeddedspeech (pid 1391): 10 MB; corespeechd (pid 1034): 11 MB; localspeechrecognition (pid 1161): 6 MB; localspeechrecognition (pid 1047): 6 MB; localspeechrecognition (pid 2088): 58 MB; localspeechrecognition (pid 1098): 6 MB; speechmaintenanced (pid 1049): 4 MB |
| m14 | Whisper | 482 MB | 912 MB | n/a |
| m14 | Diarization | 717 MB | 2424 MB | n/a |
| m15 | Apple | 194 MB | 199 MB | com.apple.siri.embeddedspeech (pid 1391): 10 MB; corespeechd (pid 1034): 11 MB; localspeechrecognition (pid 1161): 6 MB; localspeechrecognition (pid 2088): 55 MB; localspeechrecognition (pid 1047): 6 MB; localspeechrecognition (pid 1098): 6 MB; speechmaintenanced (pid 1049): 4 MB |
| m15 | Whisper | 495 MB | 912 MB | n/a |
| m15 | Diarization | 793 MB | 2424 MB | n/a |
| m16 | Apple | 165 MB | 199 MB | com.apple.siri.embeddedspeech (pid 1391): 10 MB; corespeechd (pid 1034): 11 MB; localspeechrecognition (pid 1161): 6 MB; localspeechrecognition (pid 1047): 6 MB; localspeechrecognition (pid 1098): 6 MB; localspeechrecognition (pid 2088): 44 MB; speechmaintenanced (pid 1049): 4 MB |
| m16 | Whisper | 427 MB | 912 MB | n/a |
| m16 | Diarization | 811 MB | 2424 MB | n/a |

## Caveats

- Apple and Whisper run on different machines; speed comparisons are cross-machine and not directly comparable.
- The reference model is a SOTA approximation, not ground truth. WER measures distance from it, not absolute accuracy.
- Text normalization (lowercase, punctuation removed, contractions expanded, numbers spelled out, fillers removed) may hide or introduce small differences.
- Apple SpeechTranscriber was run with alternatives enabled; production would not use alternatives.
- The Apple speech asset version is unknown (assets update silently).
