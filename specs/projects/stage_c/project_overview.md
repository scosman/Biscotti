---
status: draft
---

# Stage C — V1 Feature Layering

Implement **Stage C** of the root `implementation_plan.md`: the V1 feature layering on top of the Stage B MVP (Record → Transcribe). Stage C covers roadmap **Projects 5–8**:

- **Project 5 — Calendar Integration**: show upcoming meetings, enrich recordings with calendar context, choose which calendars count. Adds `Calendar` + `RemoteConfig` (first slice) modules, calendar permission, calendar-selection settings, upcoming display in menu bar / list, calendar context on a meeting.
- **Project 6 — Meeting Detection, Background Operation & Notifications**: run in the background (tray-first, no window required), detect meetings starting (calendar-driven + ad-hoc audio), notify with record/stop actions and an auto-stop countdown, launch-on-startup. Adds `MeetingDetection` + `Notifications` modules, the first real `AppCore` slice, menu-bar wiring, and app-target background activation.
- **Project 7 — Home, Library & Search**: a home/welcome screen, a rich meeting library (full past/upcoming lists with grouping), and search across all meetings (title/people/transcripts). Adds `HomeUI` + `SearchUI`, rich slices of `MeetingListUI`/`MeetingDetailUI` (audio playback, transcript-version switching, notes editing, association correction), full `AppShellUI` sidebar + search entry, and transcript-text search in `DataStore`.
- **Project 8 — Onboarding, Settings & Custom Vocabulary**: a real first-run wizard (permissions with denial-fix guidance, calendar selection, model download with progress + disk check), settings (custom-vocab editing, launch-on-startup, calendar selection), and the `Vocabulary` module (app-wide list + per-meeting merge) wired into `TranscriptionService`.

End of Stage C = **feature-complete V1**: onboarding → detect/record → diarized transcript (with custom vocab) → home/library/search, all on-device. (Distribution/signing is Project 9, out of scope here.)

## How this project runs

- **Fully autonomous.** No human signoff / review / stopping during development. Plan now, then implement all phases autonomously. Add **one final phase** for "human review, feedback and bug fixing," where the user reviews on real hardware and we tune together.
- **Technical decisions, two-track:**
  - **Core / important decisions** are surfaced **now, during specing** — presented with a recommendation and alternatives, for the user to confirm.
  - **Smaller decisions during development** are made autonomously without stopping, and logged to **`specs/projects/stage_c/review_for_human.md`** for review in the final phase.

## UI principles

- **Uber-native SwiftUI.** Use native SwiftUI controls and the default Apple look. No effort spent on custom rendering (corners, gradients, colors, custom controls) — we want a tight, Apple-native feel and a good starting point to design from later. This is *not* license to be lazy about design.
- **Interaction design matters deeply.** Follow the guidance the user gives during specing, top UX design principles, and Apple HIG.

## Testing

- Since the work is autonomous, **write great tests.** Use Swift tests (swift-testing) to confirm behavior; run the test hooks (`mcp__hooks-mcp__precommit_checks`, etc.). View models and orchestration must be unit-testable headlessly per the architecture's thin-app convention.

## Implementation management

- At the top level, take the **"manage only"** role seriously — Stage C is many steps. Subagents do the implementation work; the top-level agent coordinates, reviews, and keeps the build green.
