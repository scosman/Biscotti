---
status: complete
---

# Implementation Plan: Onboarding Redesign

Two phases. Phase 1 is an isolated, low-risk refactor that de-risks Home. Phase 2
is the onboarding refresh itself — necessarily atomic, because reshaping the
`OnboardingViewModel.Step` enum breaks every onboarding view at compile time, so
the VM refactor, the new views, and the test migration must land together.

See `functional_spec.md` (behavior contract), `ui_design.md` (visuals),
`architecture.md` (the step-machine refactor + test migration plan).

## Phases

- [x] **Phase 1 — Extract `BrandFooter` to DesignSystem.**
  Promote Home's private `HomeFooter` into `public struct BrandFooter` in
  `DesignSystem` (drop the baked `.padding(.top, 30)`); rewire `HomeUI/HomeView`
  to use `BrandFooter().padding(.top, 30)` so Home is pixel-identical. Pure
  refactor; `make ci` green. (architecture §3.1)

- [x] **Phase 2 — Onboarding refresh (atomic).**
  - **VM step-machine refactor** (architecture §2): 5-case `Step` enum;
    `rawValue`-based `progressIndex`/`totalSteps`; split `requestPermission()`
    into `requestMicrophone/SystemAudio/Calendar/Notifications`; unify
    `advance`/`skip` into state-based `proceed()`; `footerButton` with
    `allPermissionsGranted` gating on `.permissions`; all-four
    `syncLivePermissionState`; remove `.launchAtLogin`, `setLaunchAtLogin`,
    `FooterButton.custom`, unused `ServiceManagement` import.
  - **New views/components** (ui_design §3–7): `OnboardingScaffold`,
    `ProgressHeader`, `OnboardingPrimaryButtonStyle`, `PermissionRow` + the
    four-row `.homeCard()`, Granted tag; rebuild `OnboardingView` /
    `OnboardingStepViews` for the 5 screens, reusing `BrandFooter`,
    `JoinRecordButtonStyle`, `InsetDivider`, `.kicker()`, `Banner`,
    `.fixPermissionsAlert`. Honor motion + reduced-motion (ui_design §8).
  - **Test migration** (architecture §6): rewrite structure tests, keep
    behavior tests (updated call surface), delete the three launch-at-login
    tests, add the new gating/progress/branch tests.
  - Verify: `make ci` green; flow completable; behavior unchanged.
