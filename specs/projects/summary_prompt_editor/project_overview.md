---
status: complete
---

# Custom Summary Prompt

Let the user customize the prompt Biscotti's on-device model uses to generate a
meeting summary.

Roughly:

- **Editor sheet.** A sheet for editing the prompt. Shows our Markdown editor with
  the current prompt. Can reset to default. Offers some pre-canned example additions
  to give the user ideas for editing it. The sheet is reusable for both scenarios
  below.

- **Scenario 1 — edit the default prompt.** From Settings, edit and save the default
  prompt. Saved to our settings and used for all future runs. No back-fill of
  existing summaries.

- **Scenario 2 — one-off per meeting.** A "Re-generate Summary" action on an
  individual meeting now shows the sheet, letting the user customize the prompt
  before running. These edits are not saved — they're used only for this one-off
  generation.

## Design notes

A design spec was produced by a "design agent" that did not have access to the
codebase and worked from earlier comps. It went a little overboard on visual flare;
we want to bring it back in line with our "SwiftUI native" look. Where the design
spec conflicts with the current codebase, existing design system, or SwiftUI
patterns, treat the spec as directional (capture its spirit) rather than
prescriptive, and resolve conflicts in favor of native conventions.
