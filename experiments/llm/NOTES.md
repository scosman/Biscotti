# Notes: Local LLM Experiment

## Build/test gotcha: orphaned `swift` processes and the `.build` lock

**Discovered during Phase 3 of the LLM XPC service project.**

When `swift build` or `swift test` is run through a timeout-capable harness (e.g. the
`hooks-mcp` MCP server used by Claude Code agents), killing the harness on timeout
**orphans the underlying `swift` process** (the build-system process, `swift-build-tool`,
or `swift-frontend`). That orphan holds the SwiftPM `.build` directory lock, which
**silently blocks all subsequent builds and tests** -- they hang indefinitely with no
error message.

### Symptoms

- `swift build` or `swift test` hangs forever after a previous timed-out build/test.
- No error output -- just a silent hang waiting for the lock.

### Recovery

Kill the orphaned process:

```bash
pkill -f 'swift-build-tool'
pkill -f 'swift-frontend'
```

Then retry the build/test.

### Mitigation

The `hooks_mcp.yaml` `build_llm` and `test_llm` timeouts were raised from 120s to 300s
to reduce the likelihood of hitting the timeout during normal builds/tests. Keep builds
and tests fast (seconds, not minutes) to stay well within the timeout.

The MCP server process (`hooks-mcp`) does not kill child process trees -- it only kills
the immediate child (the `bash -c ...` wrapper). The `swift` process is a grandchild
and survives. This is a known limitation of the hooks-mcp architecture; a process-group
kill would fix it but is not yet implemented.
