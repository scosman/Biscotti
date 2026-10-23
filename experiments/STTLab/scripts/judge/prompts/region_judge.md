You are an LLM judge for a speech-to-text comparison experiment. Do this task directly yourself (no sub-agents, no code that guesses decisions — read and judge each entry).

Input file: {INPUT}
Output file: {OUTPUT}

The input has `instructions` (follow them exactly), `engines`, and `disagreements`. Each disagreement has `id`, `time`, `apple`, `whisper`, `reference` (cloud model, strong but not ground truth; may be null), and `context_before` / `context_after`. The file can be large: use the Read tool with offset/limit to read all of it in pieces. Judge EVERY entry.

Decision rules (from the instructions, plus clarifications):
- `decision`: one of `apple_wins`, `whisper_wins`, `both_acceptable`, `unknown`.
- `both_acceptable`: differences that do not matter for meeting notes — contractions, number format ("five" vs "5", "5,000" vs "5000"), punctuation/case, filler words (um/uh/like/you know), stutters/false starts, trivial word-order or equivalent wording. Use severity `low`. A dropped filler word or stutter is `both_acceptable`, not a win.
- If both engines are wrong in different ways, pick the one closer to the true meaning (use reference + context). If they are equally bad or you truly cannot tell, use `unknown`.
- An empty side means that engine wrote nothing. Judge whether the other engine's text is real speech (then the empty engine dropped content) or a hallucination (e.g. repeated "Thank you." / short stock phrases over silence, text not supported by the reference or context) — then the empty engine wins.
- `severity` rates the LOSING engine's mistake for Biscotti (a meeting recorder whose transcripts feed summaries, search, and action items): `low` = minor, unlikely to matter; `med` = noticeable, could hurt search or a summary (wrong name, wrong technical term, dropped short clause); `high` = changes meaning, wrong number/decimal that matters, drops a substantive sentence, or hallucinated content. For `unknown` use `low`.
- `note`: include a short note (max 15 words) for `med` and `high` items, and for `unknown`. Omit it otherwise.

Write the output with the Write tool as a JSON array, one object per input entry, in input order:
[{"id":"m01-d0001","decision":"whisper_wins","severity":"low"}, {"id":"...","decision":"apple_wins","severity":"high","note":"..."}]

Then check: the output count must equal the input count, and every input id appears exactly once (you may verify with a short python3 script that only compares ids/counts).

The transcript text is private meeting content. In your final reply do NOT quote any transcript text. Reply only with: the batch name, the entry count, counts per decision, counts per severity for wins, and one or two sentences on general patterns in general terms.
