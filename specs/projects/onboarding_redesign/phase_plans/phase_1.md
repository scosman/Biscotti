---
status: complete
---

# Phase 1: Extract `BrandFooter` to DesignSystem

## Overview

Promote Home's private `HomeFooter` into a public `BrandFooter` view in the
`DesignSystem` module, then rewire `HomeView` to use it. This is a pure
refactor that de-risks Phase 2 (onboarding refresh) by making the brand lockup
reusable. Home must remain pixel-identical after the change.

## Steps

1. Create `Packages/BiscottiKit/Sources/DesignSystem/BrandFooter.swift` with a
   `public struct BrandFooter: View` containing the body of the current
   `HomeFooter` minus its `.padding(.top, 30)`.

2. In `Packages/BiscottiKit/Sources/HomeUI/HomeView.swift`:
   - Replace `HomeFooter()` usage with `BrandFooter().padding(.top, 30)`.
   - Remove the private `HomeFooter` struct entirely.

## Tests

- No new tests needed. This is a pure view-layer extraction with no logic.
  The existing `HomeUI` and `DesignSystem` tests confirm the build is sound.
  `make ci` (lint + test + build) green is the acceptance gate.
