---
status: complete
---

# Implementation Plan: Project 0 — Scaffolding & Tooling

Phased build order. Detail for every file lives in [`architecture.md`](architecture.md); this is just the sequence and the per-phase "done" check. Four phases, each independently reviewable, each leaving something green.

**Reordering note (vs. the original 3-phase plan):** `hooks-mcp` was pulled forward to **Phase 2** because the Bash-tool sandbox cannot run `swift build`/`swift test`/`xcodebuild` (llbuild's build-system file writes hit a silent sandbox denial; SwiftPM flags, scratch-path redirects, and `--disable-sandbox` don't fix it — they only work unsandboxed). `hooks-mcp` runs the `make` targets in the MCP server process, **outside** the Bash sandbox, so agents invoke `build`/`test`/`lint` via MCP tools with no sandbox limits and no per-command permission prompts. Establishing that command surface first unblocks the app/CI phases. Consequently the old Phase 2 (app target) became Phase 3, and the rest of the old Phase 3 (CI/hooks/docs) became Phase 4. (`make lint`/`make format` already run sandbox-clean via `--cache ignore`/`--no-cache`; only the compile/xcodebuild targets need the MCP path.)

## Phases

- [x] **Phase 1 — Swift package + command surface (the gating core).**
  Create `Packages/BiscottiKit` (`Package.swift`, placeholder `BiscottiKit.swift`, Swift Testing test); the `Makefile` (`help/bootstrap/build/test/lint/format/clean`); `Brewfile`, `.swiftformat`, `.swiftlint.yml`, `.gitignore`.
  **Done when:** `make bootstrap` installs tools, `make test` is green, `make lint` is clean (and `make format` is a no-op on the clean tree). *(Committed: c3ff67c.)*

- [x] **Phase 2 — Agent command surface via hooks-mcp.**
  Create `hooks_mcp.yaml` (actions = thin wrappers over the `make` targets) and `.mcp.json` registering the `biscotti-hooks` server (`uvx hooks-mcp`). `uv` is **already installed outside Homebrew** — do **not** add it to the `Brewfile`. Include the actions whose targets work today (`bootstrap`, `build`, `test`, `lint`, `format`); `generate`/`build_app`/`test_app` actions may be stubbed now but only become runnable once the app target lands in Phase 3. XcodeBuildMCP (npx/node) is deferred to Phase 4.
  **Done when:** `.mcp.json` + `hooks_mcp.yaml` are valid and `uvx hooks-mcp` launches and lists the actions; after the user enables the server in Claude Code (one-time approval — note for the human), `build`/`test`/`lint`/`format` run **green via the MCP tool** (not Bash), confirming the sandbox is bypassed. *(Committed: 7417dfc.)*

- [x] **Phase 3 — Thin app target via XcodeGen.**
  Create `App/` (`project.yml`, `Sources/BiscottiApp.swift` bare window, `Resources/Info.plist` usage strings, placeholder `Assets.xcassets`, `Biscotti.entitlements`); add `generate/build-app/test-app` to the `Makefile`; add the corresponding `generate`/`build_app`/`test_app` actions to `hooks_mcp.yaml` if not already present.
  **Done when:** `make build-app` (run via hooks-mcp) generates the project and builds ad-hoc, and launching the built app shows the placeholder window rendering `BiscottiKit.marker`. (One-time manual launch, recorded in the phase notes.)

- [ ] **Phase 4 — CI, git hooks, XcodeBuildMCP, and docs.**
  Add `.github/workflows/ci.yml` (gating `package-tier` + non-gating `app-tier`); `.githooks/pre-commit` + `make hooks`; add the `xcodebuildmcp` server to `.mcp.json` and `node` to the `Brewfile` (for `npx`); update root `CLAUDE.md` ("Build & checks" section documenting the Makefile, the two CI tiers, and **hooks-mcp as the agent command surface**; remove the "not scaffolded yet" caveats); correct the bundle ID in `research/permissions/README.md`.
  **Done when:** CI runs on a branch with `package-tier` green (then set as the required check), `app-tier` reporting non-gating; `make hooks` + a deliberate violation blocks a commit; `xcodebuildmcp` actions are listable; docs reflect reality.

## Notes

- Verify toolchain-dependent specifics against the **installed** versions as you go (per architecture's call-outs): SwiftLint flag/rule names, and the `uvx hooks-mcp` / `npx xcodebuildmcp` invocations against current upstream READMEs.
- `uv` is already installed (not via Homebrew); the `Brewfile` does not and should not list it. `node` is added in Phase 4 for XcodeBuildMCP.
- Each phase ends with the standard CR loop + commit. The branch-protection "required check" setting (Phase 4) is a one-time GitHub UI action, not code — note it for the human. Enabling the MCP servers in Claude Code (Phase 2 hooks-mcp; Phase 4 XcodeBuildMCP) is likewise a one-time user action.
