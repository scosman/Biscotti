---
status: complete
---

# Improve AI Analysis

## Issues we are addressing

- We have several AI tasks per job. The transcript might be 20k tokens, and we have to
  parse it twice (summary, infer speakers), which is a big waste.
- There's no way to run "infer speakers with AI" on older chats in the UI currently.

## The Fix

One "analysis" chat, for all items (infer speakers, summary, anything else). Reusing the
KV cache, as a multi-turn chat:

- **System message**: explain task (will provide meeting transcript, will ask questions
  related to it across several turns, like infer speakers and generate summary).
- **User message**:
  - Optional: Meeting details provided in `<meeting_details>...</meeting_details>` tags.
    Name, invitees, description, etc.
  - Optional: speaker ID to user mappings (only those set by a human user)
    `<user_speaker_person_mapping>...</user_speaker_person_mapping>`.
  - transcript in `<transcript>...</transcript>` tag
  - Task at end, explaining the infer speaker names task. Explain formatting
    requirements. Similar to how it works today, but new order. Add that
    `user_speaker_person_mapping` should be respected, and its job is only to assign
    currently unassigned speakers.
- **assistant message**: returns speaker names, formatted.
- **user message**: task request meeting summary.
  - it has assistant message about names in context, so can use that info too. Has
    transcript and meeting details already. All reused.
- **assistant message**: with summary.

Note: may add an extra turn later: generate an AI name for the meeting.

## UI notes

- Settings: reduces down to one toggle for AI analysis, not separate for infer speakers
  and summary.
  - "AI Analysis & Summary" / "Generate a summary from the transcript, and guess the
    names of speakers from context." Toggle, default on like the others.
- "Regenerate Summary" on meeting detail page should do both infer names and summary. No
  need to rename it, can do both under current name.
- If the user manually set speaker names, they will be flagged (done already). Pass this
  in as context when they exist. Never overwrite these with AI guesses, even if the model
  messes up and returns some.

## Service

The LLM XPC service only takes system and user. We'll need to update it to a more
standard chat format.

- take a list of messages, not just system/user.
- ensure we reuse KV cache if the next call has the same prefix
  - First call `llm(A, B) -> C`
  - Second Call `llm(A, B, C, D) -> E` — A, B, C are all cached/instant.

## Phases (can tweak, but want clean separate phases)

- modify LLM XPC service to take new list-of-messages format. Verify with manual test app.
- modify LLM XPC service to reuse KV cache when chat list prefix matches last call. Verify
  with manual test app.
- Update app code to make use of the new APIs, doing the multi-turn analysis described
  above.
- Settings/UI cleanup.
