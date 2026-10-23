You are categorizing transcription mistakes. Do the work directly yourself (no sub-agents, no scripts that guess).

Input: {INPUT}
Output: {OUTPUT}

Each entry is one disagreement region that an earlier judge decided. `loser` is the engine that made the mistake (`apple` or `whisper`); `severity` is `med` or `high`. You see the Apple text, the Whisper text, the reference text (a strong cloud model, not ground truth; may be null) and the earlier judge's short note. Use the Read tool with offset/limit to read the whole file. Categorize EVERY entry.

Pick the ONE category that best describes the LOSER's mistake:
- `technical_term`: a domain term, tool, product, framework, acronym or jargon word is misrecognized (e.g. a software term heard as a common word).
- `person_name`: a person's name is wrong or garbled.
- `number_or_version`: a number, decimal, version, percentage, date or quantity is wrong or missing.
- `dropped_content`: the loser wrote nothing (or almost nothing) where real speech was said.
- `hallucination`: the loser wrote text that was not said (e.g. repeated stock phrases over silence).
- `meaning_change`: a common word is replaced so the meaning changes (negation flip, wrong verb/noun), not a technical term.
- `garbled_phrase`: several words in a row are nonsense or unreadable.
- `other`: none of the above.

Write a JSON array with the Write tool, one object per input entry, in input order:
[{"id": "m01-d0001", "category": "technical_term"}, ...]

Check that the output count equals the input count and every id appears once. The text is private meeting content: in your final reply do NOT quote any of it. Reply only with "done", the entry count, and counts per category.
