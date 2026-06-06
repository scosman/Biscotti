---
status: draft
---

# Phase 2: Agent command surface via hooks-mcp

## Overview

Establish the MCP-based agent command surface so that coding agents can invoke build/test/lint/format targets outside the Bash-tool sandbox. The Claude Code Bash sandbox silently denies llbuild's build-system file writes, making `swift build`/`swift test`/`xcodebuild` fail. hooks-mcp runs `make` targets in the MCP server process (outside the sandbox), bypassing this limitation.

This phase creates two files at repo root:
- `hooks_mcp.yaml` — named actions wrapping each Makefile target.
- `.mcp.json` — registers the `hooks-mcp` MCP server for Claude Code auto-discovery.

XcodeBuildMCP is deferred to Phase 4.

## Steps

1. Create `hooks_mcp.yaml` at repo root with `server_name`, `server_description`, and an `actions` array. Each action wraps one Makefile target: `bootstrap`, `generate`, `build`, `test`, `lint`, `format`, `build_app`, `test_app`. Actions whose underlying targets require the app target (`generate`, `build_app`, `test_app`) are included but only become runnable after Phase 3 lands the app target.

2. Create `.mcp.json` at repo root with the `mcpServers` object containing only the `hooks-mcp` entry (`uvx hooks-mcp`; `hooks-mcp` defaults to cwd, so no `--working-directory` arg). Do NOT include `xcodebuildmcp` — that is Phase 4.

3. Verify `hooks_mcp.yaml` parses correctly by running `uvx hooks-mcp` with the config and checking it starts / lists actions without errors.

4. Validate `.mcp.json` is well-formed JSON.

## Tests

- Validation: `uvx hooks-mcp` starts successfully and lists the defined actions (manual verification via the CLI).
- Validation: `.mcp.json` parses as valid JSON with the correct `mcpServers` structure.
- Validation: `make lint` and `make format` still pass cleanly (no regressions from new files).
- Note: running `build`/`test` through the MCP server is a one-time user step after enabling the server in Claude Code settings — not automated here.
