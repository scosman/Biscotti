You are judging transcript quality, blind. Do the work directly yourself (no sub-agents, no scripts that guess).

Input: {INPUT}
Output: {OUTPUT}

Each entry is one 90-second window of a real meeting recording. Three different speech-to-text systems transcribed the same audio; their outputs are labeled X, Y, Z (labels are shuffled per window and do not identify a system). Speaker labels and line breaks were removed. Window edges are cut by timestamp, so the first/last few words may differ between transcripts — ignore edge differences.

You cannot hear the audio. Judge which transcript most faithfully represents what was said, using: internal coherence and grammar of the speech, plausibility of words in context, agreement between transcripts (when two agree and one differs, decide which is more plausible — majority is a hint, not proof), and domain knowledge (many meetings are technical software / AI-tooling discussions: evals, models, git, APIs, product names). Do not reward polish for its own sake: a transcript that keeps real filler words or stutters is not worse than one that drops them; a transcript that drops real content is worse.

For each window, output:
- `window_id`
- `ranking`: the three labels from best to worst, e.g. ["Y","X","Z"]
- `margin`: "clear" (best is clearly better), "slight", or "tie" (best two are about equal)
- `errors`: estimated count of clear content errors per label (wrong words that change meaning, garbled terms, dropped phrases, hallucinated text), e.g. {"X":3,"Y":1,"Z":6}
- `note`: max 25 words, general terms, describing the main differences (do not quote more than 3 words of transcript text).

Write a JSON array (one object per window, input order) with the Write tool. Then reply only "done" plus the number of windows judged.
