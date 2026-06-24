---
status: complete
---

# Implementation Plan: Dark Mode

Three phases. Phase 1 is the foundation and makes most of the app adapt; Phase 2
is the split-token repoints + hardcoded-site fixes + automated/functional
verification; Phase 3 is a dedicated **human visual review of the agent's
decisions**. Details live in `functional_spec.md` (token map, repoint list) and
`architecture.md` (mechanism, tests). Keep light byte-identical throughout.

## Phases

- [x] **Phase 1 — Adaptive palette foundation (+ guarantee tests).**
  - Add `DesignSystem/DynamicColor.swift` (the single appearance-resolving helper).
  - Rewrite `Color+Theme.swift`: every existing token → `dynamicColor(light:dark:)`
    with light = exact current literal, dark = functional-spec §3 value. Unify the
    `Color`/`NSColor` definitions into one source. Preserve `ShapeStyle` sugar.
  - Add the new tokens: `accentFill`, `read`, `elevatedFill`, `accentTrack`,
    `signalRedText`, `cardShadow`, `controlShadow` (light = the literal each
    replaces).
  - Update `Tokens.swift`: `cardFill` adaptive; `warningChipText` to its own dark
    value; add aliases for the new tokens; leave avatar/type/spacing/radii.
  - Add `DesignSystemTests`: Test 1 (every token's `.aqua` == legacy literal —
    the byte-identical-light guard), Test 2 (`.darkAqua` == design hex), Test 3
    (no `colorScheme` conditionals in view code).
  - Green `make lint` + `make test` (via `hooks-mcp`). No call-site repoints yet —
    after this phase the app already renders dark for all redefined tokens.

- [ ] **Phase 2 — Split repoints, hardcoded sites, verification.**
  - Repoint the ≈16 call sites in functional-spec §4: `accentFill` button fills,
    `elevatedFill` (button style + focused title field), `read` transcript body,
    `signalRedText` red-text labels, `accentTrack` progress bars, and the two
    `.black` shadows → `cardShadow`/`controlShadow`.
  - Confirm hardcoded "stays" sites are untouched (white labels/sheen, avatars,
    material, calendar hex, native controls) — functional-spec §5.
  - Green `make lint` + `make test`; `make build-app` (non-gating) builds.
  - **Functional dark-mode smoke pass** (architecture §5): live Light↔Dark toggle
    across Home, Meeting Detail, Active Recording, Upcoming, Onboarding, Settings,
    model sheets, banners, menu-bar, markdown editor. Confirms *correctness* — no
    white-on-light / light-on-light defects, nothing unreadable. (Aesthetic
    sign-off is Phase 3.)

- [ ] **Phase 3 — Human visual review of agent decisions.**
  This project is the agent interpreting design *comps* against the real code, so
  every color choice gets an explicit human eyeball before it's considered done.
  - **Agent prepares a review packet:** run the app and capture **side-by-side
    light/dark screenshots** of each surface (Home, Meeting Detail incl. transcript
    + notes, Active Recording incl. Stop&Save / REC pill / Elapsed + amber ≤5:00
    chips / RECORDING badge, Upcoming, Onboarding, Settings, model sheets, error +
    warning banners, menu-bar popover, markdown editor). Annotate each shot with the
    **decisions that landed there**, drawn from:
    - the §6 judgment calls (`signalRedText`, `accentTrack`, amber non-split),
    - the §3.6 *skipped* comp elements (flat where the comp used a gradient:
      window backdrop, cards, record pill/button, progress tracks),
    - any token whose dark value is applied in an unusual context.
  - **Human reviews decision-by-decision**, not just "does it render": does each
    dark value read well *in situ*; does any flat-instead-of-gradient or
    skipped-token surface look wrong; are the splits/non-splits the right call.
  - Capture every delta as a concrete tweak (token value or a missed
    repoint/split) and fold the small adjustments back in. Light must stay
    byte-identical (Phase 1 Test 1 re-runs green after any tweak).
  - Sign-off here is the project's acceptance gate.

## Notes
- No `Packages/Transcription`, `AudioCapture`, or `LocalLLM` files are touched —
  the manual-test gate for those is unaffected.
- The two optional splits (`signalRedText`, `accentTrack`) can be dropped if the
  reviewer prefers a more minimal palette (functional-spec §6); that only removes
  two tokens and a few repoints.
