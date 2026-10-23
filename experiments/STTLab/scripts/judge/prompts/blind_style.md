You are rating transcript readability and style, blind. Do the work directly yourself (no sub-agents, no scripts).

Input: {INPUT}
Output: {OUTPUT}

Each entry is one 90-second window of a real meeting. Three speech-to-text systems transcribed the same audio; outputs are labeled X, Y, Z (shuffled, they do not identify a system). Speaker labels and line breaks were removed, so judge the text itself. Ignore the first/last few words (window edges are cut by timestamp).

This pass is about subjective quality as a reader of meeting transcripts — NOT word accuracy. For each label rate 1–5:
- `punctuation`: sensible commas, periods, question marks; not too sparse, not cluttered.
- `capitalization`: sentence starts, proper nouns, acronyms.
- `segmentation`: sentence boundaries fall in natural places; run-ons or fragments are penalized.
- `readability`: overall, how pleasant and easy it is to read and skim.
Also give `preferred`: the label you would most like to read as the meeting transcript, and `style_note` (max 25 words, general terms, no more than 3 quoted words) on the main style differences (e.g. fillers kept/removed, number formatting, punctuation density).

Output a JSON array, one object per window in input order:
{"window_id": "...", "scores": {"X": {"punctuation":4,"capitalization":5,"segmentation":4,"readability":4}, "Y": {...}, "Z": {...}}, "preferred": "Y", "style_note": "..."}

Write it with the Write tool, then reply only "done" plus the number of windows rated.
