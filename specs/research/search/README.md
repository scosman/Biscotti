# Search Performance — Validated Findings

**Date:** 2026-08-25 · **Hardware:** Mac16,8 (M4 family), 48 GB RAM, macOS 15.6.1

Answers the question "does Biscotti need a real full-text index (Core Spotlight or
FTS5), or can the existing store be made fast enough?"

**Answer: no index needed for the foreseeable future.** Querying the SwiftData
SQLite file directly with SQL is **288× faster** than the current search at 5000
meetings, with no schema change, no migration, and no data duplication.

---

## The problem with the current search

`DataStore.searchHits(_:limit:)` (`DataStore+ReadModels.swift`) fetches **every**
`Meeting`, then walks relationships in memory — participants, tags, transcripts,
and every transcript segment — running `localizedStandardContains` per term.

The cost is **SwiftData/Core Data faulting**, not string matching. At 5000
meetings it materializes ~500,000 segment objects, each allocated, registered in
the context, and enrolled in change tracking. Isolating the two (see
`fetch+fault` row below) shows string matching is only **2–3%** of the total.

A **rare** term is the realistic user query (a name, a project) and the worst
case: it cannot short-circuit, because proving "not present" requires reading
every segment. A **common** term looks deceptively fast only because
`contains(where:)` stops at the first match.

---

## Benchmark results

Synthetic data: 5000 words of transcript per meeting (100 segments × 50 words),
generated on-disk SwiftData stores. Median of 3 warm runs.

### Current implementation (`searchHits`)

| Tier | common "the" | **rare term** | multi-term | fetch+fault only |
|---|---|---|---|---|
| 50 | 20.2 ms | **384.6 ms** | 39.2 ms | 375.8 ms |
| 500 | 203.9 ms | **3,829 ms** | 390.2 ms | 3,732 ms |
| 5000 | 2,267 ms | **39,479 ms** | 3,990 ms | 38,101 ms |

Scaling is linear. Cold ≈ warm at every tier, so caching does not rescue repeat
searches. Store size at 5000 meetings: **284 MB**, 500,000 segment rows.

### Raw SQL against the same stores

| Tier | rare (warm) | rare (cold) | common "the" (warm) |
|---|---|---|---|
| 50 | **0.9 ms** | 1.6 ms | 2.6 ms |
| 500 | **14.3 ms** | 14.6 ms | 39.3 ms |
| 5000 | **137 ms** | 1,607 ms | 418 ms |

| Tier | rare speedup | common speedup |
|---|---|---|
| 50 | 428× | 7.8× |
| 500 | 268× | 5.2× |
| 5000 | **288×** | 5.4× |

Correctness was verified against the Swift implementation at every tier
(`swift=2 sql=2` for the rare term, including the preferred-transcript filter).

A scan-only variant (no joins) covers 500,000 rows / 284 MB in **257 ms** —
roughly 1.1 GB/s. The joins are nearly free (137 ms vs 142 ms scan-only). The
bottleneck was never I/O or string comparison; it was object materialization.

---

## Core Data store schema (validated by dumping a generated store)

SwiftData is Core Data underneath, and the file is ordinary SQLite in WAL mode.
**Core Data does not block read queries**; a second read-only connection is fine.

Tables: `ZMEETING`, `ZTRANSCRIPTRECORD`, `ZTRANSCRIPTSEGMENTRECORD`, `ZPERSON`,
`ZTAG`, plus join tables `Z_4PARTICIPANTS` / `Z_4TAGS` and Core Data's own
`Z_METADATA`, `Z_MODELCACHE`, `Z_PRIMARYKEY`.

Key columns:

| Table | Columns of interest |
|---|---|
| `ZMEETING` | `Z_PK`, `ZID` (BLOB uuid), `ZTITLE`, `ZNOTES`, **`ZSUMMARY`**, `ZPREFERREDTRANSCRIPTID` (BLOB) |
| `ZTRANSCRIPTRECORD` | `Z_PK`, `ZID`, **`Z4TRANSCRIPTS`** → FK to `ZMEETING.Z_PK` |
| `ZTRANSCRIPTSEGMENTRECORD` | `Z_PK`, `ZTEXT`, **`Z7SEGMENTS`** → FK to `ZTRANSCRIPTRECORD.Z_PK` |

**The parent foreign keys already exist**, even though the Swift models declare no
inverse relationship. Core Data names an undeclared-inverse FK
`Z<entityNumber><parentRelationshipName>`. This is why no new field is required.

`ZID` is a 16-byte **BLOB**, so use `hex(ZID)` to read UUIDs as text.

### The validated query

```sql
SELECT DISTINCT hex(m.ZID)
FROM   ZTRANSCRIPTSEGMENTRECORD s
JOIN   ZTRANSCRIPTRECORD t ON s.Z7SEGMENTS    = t.Z_PK
JOIN   ZMEETING          m ON t.Z4TRANSCRIPTS = m.Z_PK
WHERE  s.ZTEXT LIKE '%term%'
  AND  t.ZID = m.ZPREFERREDTRANSCRIPTID   -- preserves "preferred transcript only"
```

---

## Risks and mitigations

1. **Entity numbers in FK column names.** The `7` and `4` in `Z7SEGMENTS` /
   `Z4TRANSCRIPTS` are Core Data entity indices and **can shift when the model
   changes** (adding or removing entities). Failure is **silent** — zero results,
   no error. *Mitigate:* resolve column names at runtime via `PRAGMA table_info`,
   assert the expected schema shape in a test, and keep a differential test
   comparing SQL results against the Swift implementation.
2. **The store format is private and undocumented.** Apple does not support
   reading it directly. In practice it is stable, but treat it as read-only —
   never write through this path.
3. **`LIKE` semantics differ from `localizedStandardContains`.** SQLite's `LIKE`
   is case-insensitive for ASCII only and does no diacritic folding, so "cafe"
   stops matching "café". A deliberate product call.
4. **Cold cost is real.** 1,607 ms cold vs 137 ms warm at 5000 meetings — the
   first search after launch pays page-cache misses.
5. **Unsaved SwiftData changes are invisible** to a separate connection. Ensure
   writes are saved before searching.
6. **Still linear.** `LIKE '%term%'` cannot use an index. This buys a large
   constant-factor win, not a better curve — fine at 5k–20k meetings, not at 100k.

---

## Why not Core Spotlight or FTS5 (for now)

Both were the original candidates for a "proper" index. Deferred because:

- At 5000 meetings the SQL path is **137 ms warm**, comfortably inside the
  existing 300 ms search debounce (`AppCore.setMeetingsQuery`).
- Both are **token-based**, so they match whole words and prefixes but not
  infixes — adopting either **changes what search finds** relative to today's
  substring matching. That is a product decision, not just a performance one.
- Revisit when a user plausibly has ~50k meetings, where the SQL path drifts
  toward ~1.4 s.

If Core Spotlight is revisited, requirements captured so far: not exposed to the
system Spotlight UI, `protectionClass: .complete`, and
`isEligibleForPublicIndexing` disabled.

---

## Reproducing

```
make bench        # NON-GATING, ~12 min, generates multi-GB stores
```

Runs both suites, each env-gated so they never run in `make test` / `make ci` /
`make precommit-checks`:

- `SearchBenchmarkTests.swift` — `BISCOTTI_RUN_BENCH=1`, current implementation
- `RawSQLSanityCheckTests.swift` — `BISCOTTI_RUN_SQLCHECK=1`, raw-SQL comparison
  and schema dump

A fast smoke test (5 meetings, ~30 ms) **does** run in `make test` to catch rot in
the data generator and measurement harness.

Both use **generated data only** and never touch the real store.
