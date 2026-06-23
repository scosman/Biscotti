---
status: complete
---

# Onboarding — Download Models (V2)

This branch (`small_llm`) added the ability to select one of two LLM models — a smaller one for
smaller Macs, a bigger one for bigger ones — including recommending a model for the user's machine.
The `llm_model_selection` spec project built that: hardware probing + suitability, the persisted
`selectedModelID`, `ModelManager`, the permanent **AI Language Model** Settings row, and the
**Manage Models** sheet (variant picker with the Recommended badge, download/delete/choose, and
the low-RAM disabling of 12B).

**This project** refactors the **onboarding "Download Local AI Models" screen** (the `.modelDownload`
step). Today that screen only downloads the **transcription** model; to get the **language model**
the user has to go to Settings afterward. We want the onboarding screen to let the user download
**both** model classes up front.

## Goals

- The onboarding models step downloads **two model classes**, each independently:
  - **Transcription & Speaker ID** (Whisper V3 Turbo, ~1.5 GB) — already wired today.
  - **Language Model** (Gemma 4 E2B or 12B, ~3–7 GB) — new on this screen.
- The language class has a **recommended** variant (from the existing hardware logic). The easy path
  is a single **Download** that pulls the recommended one; a **"See all options"** affordance opens
  the **existing Manage Models sheet** to pick a variant.

## Reuse-first constraints (from the human)

- **Reuse existing code:** the existing **Manage Models sheet** for "See all options" — **minimal or
  no new code**. Reuse the existing logic for checking whether a model is already downloaded, the
  recommendation logic, download/progress machinery, etc. Refactor out of Settings into shared
  helpers only if needed to share it.
- A **design spec** (below, in the project context) from our design agent guides the visual update.
  The design agent was **not** aware of the code and didn't make all UI decisions (e.g. the
  Skip-only-until-all-downloaded footer rule already lives in code and has UI feedback/love). Treat
  the design as **guidance, not overruling decisions already made in code**. Where the design
  **conflicts** with code, raise clarifying questions during speccing rather than blindly following.

## Out of scope

- The Settings AI Language Model row and Manage Models sheet themselves (already shipped) — beyond
  any refactor needed to reuse the sheet from onboarding.
- Cancelling a download mid-flight (Skip still abandons the step; downloads continue in the
  background and finish, matching existing behavior).
- Changing the rest of the onboarding flow (window, scaffold, progress header, footer mechanics,
  welcome / permissions / calendar / done steps).
