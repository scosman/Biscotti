---
status: draft
---

# Configurable Model Storage

I want to make the storage location (directory) for the models configurable.

- If I change it, move the models, don't re-download.
  - Atomic folder move ideally so either full success (move and set new location) or full failure (no location change, no move)
  - Fast fail if destination doesn't have enough space
- UI
  - A new sheet we can use across onboarding and settings.
    - Title "Model Storage Location"
    - Body "AI models can be large, control where Biscotti stores them."
    - Show current on a line "Current Directory: Default (Application Support)"
    - Button row:
      - Open (opens folder)
      - Change Location (opens folder selector)
      - "Restore Default" only if non default
    - UX: if you select a location on an external drive show a confirmation. "Use External Drive?" "If this drive isn't connected, Biscotti can record, but won't be able to transcribe or summarize meetings." [cancel] [OK]
  - Settings entry point in "AI Enhancements"
    - title "Model Storage Location", button "Manage", no subtitle, opens sheet
  - Onboarding entry point: TBD, propose one.
- Verify app handles missing models well
  - It will be more common for folks to have models on external drives. Check I can still record, and just run AI later when I connect. Should already be the case, but audit.
