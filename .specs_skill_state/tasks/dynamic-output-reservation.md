---
status: complete
created: 2026-06-21
---

# Task: Dynamic output reservation (3k + 15% of input)

## Request

making great. One last tweak. make the 3k size dynamic. 3k + 15% of input length, so it grows for very long meetings.

## Notes

Small caller-side change in `Packages/BiscottiKit/Sources/Intelligence/ContextSizing.swift`. Today the output reservation is a fixed `3072` (`outputTokenReservation`). Make it grow with input:

- `outputReservation(inputTokens) = 3072 + round(0.15 * inputTokens)`  (3k base + 15% of input token count)
- `contextSize = min(inputTokens + outputReservation(inputTokens), maxContextSize)` — keep the existing 32k cap.

Equivalent to `min(inputTokens * 1.15 + 3072, 32768)`, but keep it expressed as **base reservation + fraction of input** so it reads clearly.

**Details:**
- Keep `3072` as a named base constant; add a named `0.15` fraction constant (e.g. `outputReservationInputFraction`). No bare magic numbers.
- "input length" = the **input token count** (the real count from the phase-2 tokenizer), not characters.
- Apply consistently in BOTH the single-prompt path (`contextSize(forInputTokens:)`) and the multi-pair path (`contextSize(forPairs:session:)` — reservation is based on the max input across pairs, matching how it already takes the max).
- The 32k cap still applies after adding the dynamic reservation.
- Keep the existing info-level log; it should reflect the new (larger) context size. Optionally include the reservation in the log if it's a clean addition.
- Integer rounding of the 15% is fine (round or floor — pick one, be consistent).

**Tests:** Update the existing `ContextSizingTests` that assert exact context sizes (the expected values change to the new formula). Add at least one case with a **large input** demonstrating the reservation grows beyond 3k (e.g. a long meeting), and confirm the cap still holds at the top end.

**Scope:** Only the reservation formula + its tests. Don't touch the phase-1/2 sizing flow, the XPC API, or the (disabled) KV experiment.

**Manual-test staleness:** Touches the `Intelligence` sizing path → mark `ai_*` steps `not-run` (recordable only). Already `not-run` on this branch; verify.
