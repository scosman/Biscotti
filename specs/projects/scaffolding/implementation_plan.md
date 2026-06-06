---
status: complete
---

# Implementation Plan: Project 0 — Scaffolding & Tooling

Phased build order. Detail for every file lives in [`architecture.md`](architecture.md); this is just the sequence and the per-phase "done" check. Three phases, each independently reviewable, each leaving something green. The app/`xcodebuild` phase is isolated (it's the historically flaky part) so its risk is contained.

## Phases

- [x] **Phase 1 — Swift package + command surface (the gating core).**
  Create `Packages/BiscottiKit` (`Package.swift`, placeholder `BiscottiKit.swift`, Swift Testing test); the `Makefile` (`help/bootstrap/build/test/lint/format/clean`); `Brewfile`, `.swiftformat`, `.swiftlint.yml`, `.gitignore`.
  **Done when:** `make bootstrap` installs tools, `make test` is green, `make lint` is clean (and `make format` is a no-op on the clean tree).

- [ ] **Phase 2 — Thin app target via XcodeGen.**
  Create `App/` (`project.yml`, `Sources/BiscottiApp.swift` bare window, `Resources/Info.plist` usage strings, placeholder `Assets.xcassets`, `Biscotti.entitlements`); add `generate/build-app/test-app` to the `Makefile`.
  **Done when:** `make build-app` generates the project and builds ad-hoc, and launching the built app shows the placeholder window rendering `BiscottiKit.marker`. (One-time manual launch, recorded in the phase notes.)

- [ ] **Phase 3 — CI, hooks, agent MCP, and docs.**
  Add `.github/workflows/ci.yml` (gating `package-tier` + non-gating `app-tier`); `.githooks/pre-commit` + `make hooks`; `hooks_mcp.yaml` + `.mcp.json`; update root `CLAUDE.md` ("Build & checks" section, remove "not scaffolded yet" caveats); correct the bundle ID in `research/permissions/README.md`.
  **Done when:** CI runs on a branch with `package-tier` green (then set as the required check), `app-tier` reporting non-gating; `make hooks` + a deliberate violation blocks a commit; `hooks_mcp` actions are listable/runnable; docs reflect reality.

## Notes

- Verify toolchain-dependent specifics against the **installed** versions as you go (per architecture's call-outs): `treatAllWarnings(as:)` vs `unsafeFlags` fallback, SwiftLint flag/rule names, and the `uvx hooks-mcp` / `npx xcodebuildmcp` invocations.
- Each phase ends with the standard CR loop + commit. The branch-protection "required check" setting (Phase 3) is a one-time GitHub UI action, not code — note it for the human.
