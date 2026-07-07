---
status: complete
---

# Phase 4: CI, git hooks, XcodeBuildMCP, and docs

## Overview

Final scaffolding phase. Adds the CI workflow (gating package-tier + non-gating app-tier), the opt-in pre-commit hook with `make hooks`, registers XcodeBuildMCP in `.mcp.json` and adds `node` to the Brewfile, updates the root `CLAUDE.md` to document the now-complete build surface, and corrects the bundle ID in `specs/research/permissions/README.md`.

## Steps

1. **Create `.github/workflows/ci.yml`** with two jobs per the architecture doc section 9:
   - `package-tier`: gating job on `macos-15`, installs dev tools via `brew bundle`, runs `make ci` (lint + test + build).
   - `app-tier`: non-gating job on `macos-15` with `continue-on-error: true`, installs `xcodegen` only, runs `make build-app`.
   - Triggered on push to `main` and on pull requests.

2. **Create `.githooks/pre-commit`** (executable) per architecture doc section 7:
   - Runs `make format`, re-stages with `git add -u`, then `make lint`, then `make test`.
   - Uses `set -euo pipefail` to block on first failure.

3. **Add `make hooks` target to the Makefile**:
   - Runs `git config core.hooksPath .githooks` and prints confirmation.
   - Add `hooks` to the `.PHONY` list and add a `ci` target alias (`lint test build`).

4. **Add `node` to `Brewfile`** (needed for `npx` which runs XcodeBuildMCP).

5. **Add `xcodebuildmcp` server to `.mcp.json`** alongside the existing `hooks-mcp` entry.

6. **Update root `CLAUDE.md`**:
   - Replace the "Current stage" paragraph to reflect scaffolding is complete.
   - Add a "Build & checks" section documenting the Makefile targets, CI tiers, hooks-mcp as agent command surface, XcodeBuildMCP, the pre-commit hook, and the locked bundle ID.
   - Remove "scaffolding in progress" caveats from the Conventions section.

7. **Correct bundle ID in `specs/research/permissions/README.md`**:
   - Change `com.biscotti.app` to `net.scosman.biscotti` in both the Recommendation section and Risk #5.

## Tests

- No new automated tests (this is a config-only phase; NA for test-writing).
- Verify lint passes on all new/modified files.
- Verify the CI YAML is valid syntax.
- Verify `.mcp.json` is valid JSON.
- Verify `make hooks` wires the hook path correctly.
- Verify the pre-commit hook is executable.
