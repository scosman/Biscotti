---
status: complete
---

# Phase 1: `AppLinks` module

## Overview

Build the pure, dependency-free `AppLinks` module: the parsed-intent types
(`AppLink`, `MeetingTarget`, `MeetingTab`), the URL parser, and the canonical
URL builder, plus exhaustive table-driven tests. Wire the target into
`Package.swift` as an exported library and add it to the `AppCore`,
`MCPServer`, and `MeetingDetailUI` dependency lists so Phases 2–3 have the
edge available. Nothing calls it yet (architecture §2).

## Steps

1. **`Packages/BiscottiKit/Sources/AppLinks/AppLink.swift`** — the types:

   ```swift
   public enum AppLink: Sendable, Equatable {
       case home
       case meetings
       case settings
       case meeting(id: UUID, target: MeetingTarget)
       case search(query: String)
       case upcoming(key: String)
       case record(title: String?)
   }

   public enum MeetingTarget: Sendable, Equatable {
       case tab(MeetingTab)
       case transcriptTime(TimeInterval)
   }

   public enum MeetingTab: String, Sendable, Equatable, CaseIterable {
       case summary, transcript, notes
   }
   ```

2. **`Sources/AppLinks/AppLinkParsing.swift`** — `AppLink.init?(url: URL)`:

   - `URLComponents(url:resolvingAgainstBaseURL: false)`; nil → reject.
   - Scheme lowercased must equal `biscotti` (R1).
   - Switch on `host?.lowercased()` (R2); unknown host → nil (R3).
   - `meeting`: path minus leading `/` → `UUID(uuidString:)` (fail → nil).
     Target resolution: `time` present → must parse as `Double` (unparseable
     → nil, R3 parse tier); else `tab` recognized (lowercased) → that tab;
     else `.tab(.summary)`. Unknown `tab` value falls back to `.summary` (R8).
   - `search`: `query` item must be *present*; value may be empty.
   - `upcoming`: `key` item must be present and non-empty.
   - `record`: `title` trimmed; empty → nil.
   - Unknown query parameters structurally ignored (R8) — first-match
     lookup helper.

3. **`Sources/AppLinks/AppLinkBuilding.swift`** — `AppLink.url: URL`:

   - Built via `URLComponents` so values are percent-encoded (R9).
   - `.meeting` with `.tab(.summary)` emits no query parameters;
     `.tab` emits `?tab=…`, `.transcriptTime` emits `?time=…`.
   - `.record(title: nil)` emits no query; non-nil emits `?title=…`.
   - Non-failable: every case maps to a well-formed URL. The encode
     failure is unreachable (fixed scheme/host, UUID path, query values
     percent-encoded by `URLComponents`), and is handled by degrading —
     drop the query, then fall back to `Self.homeURL` — rather than
     trapping. A `fatalError` here would be a crash in a leaf module the
     MCP server links.

4. **`Package.swift`**:

   - `.library(name: "AppLinks", targets: ["AppLinks"])` product.
   - `AppLinks` target (Foundation only) + `AppLinksTests` test target,
     both with `warningsAsErrors`.
   - Add `"AppLinks"` to the `AppCore`, `MCPServer`, and
     `MeetingDetailUI` target dependency lists.

5. **`Tests/AppLinksTests/AppLinkParsingTests.swift`** — table-driven
   `(urlString, expected: AppLink?)` covering every route, the §4.4
   resolution order (including `tab`+`time` conflict → time wins, and
   unparseable `time` → whole URL rejected per R3), case-insensitivity of
   scheme/host/tab value, percent-decoding of `query`/`key`/`title`,
   unknown parameters ignored, `search?query=` empty vs absent, `record`
   title trimming / whitespace-only, and every parse-tier rejection
   (wrong scheme, unknown host, no host, malformed UUID, unparseable
   time, missing required parameter).

6. **`Tests/AppLinksTests/AppLinkBuildingTests.swift`** — build→parse
   round-trip over every case and associated value, plus exact
   URL-string assertions for the canonical forms the MCP server and
   Copy Meeting Link will emit (`biscotti://meeting/{uuid}`, lowercase
   tab names, `?time=` numeric formatting).

## Tests

- `parses` (parameterized): each route × parameter combination against
  the expected `AppLink`.
- `rejects` (parameterized): each parse-tier failure returns nil.
- `roundTripsThroughParse` (parameterized): `AppLink(url: link.url) == link`
  for every case of the vocabulary.
- `buildsCanonicalURLs` (parameterized): exact `absoluteString` for the
  canonical builder outputs.

Out of scope here: the existence failure tier (needs the store — Phase 2
`AppCoreTests`) and any caller wiring.
