---
status: complete
---

# LLM Features

This project adds the LLM-powered features to Biscotti. The LLM XPC service (`BiscottiLLM.xpc`, the `LocalLLM` package) is already done and **should not be touched** in this project (unless we find important issues) — this is about *integrating* it.

## General goals

- Develop nice patterns for implementing LLM features (where prompts are stored, etc.).
- Use our LLM XPC service, but build the app logic into an **in-process component**. Don't dirty the LLM XPC service with app-specific scenario code — keep it a general LLM service.

## Summarize feature

- **LLM:** System instruction to summarize, user message with the meeting transcript, produces markdown notes in the assistant message.
- **UI:** Add a "Summary" tab (the first tab) on the meeting detail page.
- Store the summary in the meeting data model, like notes.
- It's **editable**: shows as editable markdown. Like the title, we have a flag that indicates if a human ever edited it (lets us know if we must keep the current version, or whether the LLM can update it).
- "Regenerate Summary" option in the "…" menu. Regenerates with the currently selected transcript. No confirmation if the existing summary is empty or auto-generated, but shows a warning/approval if the user has edited it.
- Ask it to generate an action items list at the end, in markdown (we had considered this a separate API call, but roll it into the summary).

## Identify Speakers feature

- **LLM:**
  - System instruction to map names from the invitee list to "Speaker 0", "Speaker 1", etc. Like "Hey Daniel — what do you think?" → the next speaker is probably Daniel.
  - User message with the invitee list when we have it (email + full name) or an explanation that we don't have invitees; always includes the meeting transcript.
  - Assistant message: JSON describing the mapping of speaker N → user.
- **UI:**
  - "Speaker 0" etc. in the UI are replaced by names when we have them.
  - Clicking a speaker name opens a sheet showing the speaker N → name mapping that can be edited (can use this feature manually, even if no LLM is downloaded). Can use a dropdown to select from existing people (invitees + existing manual people) or add a manual person by typing a name.
  - The mapping of speaker ID → person is stored in the **transcription** data model, not the meeting. It will change when we re-transcribe, and the LLM job or manual mapping must be re-done. The data model supports people with name and email, or just name.

## Settings

- New settings section: "AI Enhancements", subtitle "AI runs locally on your Mac."
- "Summarize Transcripts" / "Automatically generate a summary of your meetings". Toggle, default on.
- "Guess Speaker Names" / "Use information from the transcript to assign speaker names." Toggle, default on.
- No-LLM-downloaded special case: both toggles disabled and off, and a new row at the bottom shows "Download Local Language AI Model?" with a download button and download status.

## Onboarding

None for now. Users need to go into settings to get this to work (download the model).

## Model

- Always use the default model (Gemma 12B QAT).

## Auto-run behavior

- When both features are on, they run right after transcription, automatically.
- Run "identify speakers" first, and use the better names when building the user message for the summary.
- Do both in **one session call** to the XPC service for maximal memory reuse / speed.
