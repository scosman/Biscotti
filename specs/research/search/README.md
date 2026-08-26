# Search Performance — Validated Findings

**Date:** 2026-08-25 (updated 2026-08-26) · **Hardware:** Mac16,8 (M4 family),
48 GB RAM, macOS 15.6.1

Answers the question "does Biscotti need a real full-text index (Core Spotlight or
FTS5), or can the existing store be made fast enough?"

**Answer: no index needed for the foreseeable future.** The hybrid search
(SwiftData predicates for scalar/relationship fields, raw SQL for transcript
segments, date-projection sort+truncate for broad queries) handles both rare and
common terms well at 5000 meetings with no schema change, migration, or data
duplication.

---

## Architecture (shipped)

`DataStore.searchHits(_:limit:)` uses a three-phase hybrid approach:

1. **Scalar predicates** (SwiftData `#Predicate`): title, summary, notes.
2. **Relationship traversal** (SwiftData): people and tags via declared inverses.
3. **Transcript SQL** (read-only `sqlite3` connection): `LIKE '%term%'` scan
   over segment text, joined to preferred transcript + meeting via dynamically
   resolved FK columns. 288x faster than SwiftData faulting at 5000 meetings.

After scoring, **assembly** takes one of two paths:

- **Few matches** (`<= limit`): fetch each `Meeting` individually through
  SwiftData. Fast because N is small (~30 ms for 100 fetches).
- **Many matches** (`> limit`): SQL-project `(startDate, createdAt)` for all
  meetings, sort by (score desc, effective date desc), truncate to `limit`, then
  fetch only the surviving rows via SwiftData. Titles are **not** projected from
  SQL -- they come from SwiftData after truncation so displayed data is always
  fresh and never stale from a second connection.

Result limit: **100** (set in `AppCore.setMeetingsQuery`).

---

## The problem with the original search

The pre-`22fe8ac` implementation fetched **every** `Meeting`, then walked
relationships in memory -- participants, tags, transcripts, and every transcript
segment -- running `localizedStandardContains` per term.

The cost was **SwiftData/Core Data faulting**, not string matching. At 5000
meetings it materialized ~500,000 segment objects, each allocated, registered in
the context, and enrolled in change tracking. String matching was only **2--3%**
of the total.

---

## Benchmark results

Synthetic data: 5000 words of transcript per meeting (100 segments x 50 words),
generated on-disk SwiftData stores. Median of 3 warm runs.

### Original implementation (pre-`22fe8ac`)

| Tier | common "the" | **rare term** | multi-term | fetch+fault only |
|---|---|---|---|---|
| 50 | 20.2 ms | **384.6 ms** | 39.2 ms | 375.8 ms |
| 500 | 203.9 ms | **3,829 ms** | 390.2 ms | 3,732 ms |
| 5000 | 2,267 ms | **39,479 ms** | 3,990 ms | 38,101 ms |

### Hybrid search (commit `22fe8ac`)

| Query | 5000 meetings (warm) |
|---|---|
| rare term | **137 ms** (288x faster) |
| common "the" (broad) | ~1,912 ms |

The broad-query bottleneck was an **N+1 assembly pattern**: `assembleHits`
called `meeting(id:)` once per scored meeting -- 5000 separate SQLite queries
plus 5000 object materializations (~1,482 ms of the 1,912 ms total).

### Shipped: date-projection assembly (commit `bc2372c`)

Measured at 5000 meetings, median of 3 warm runs:

| Query | Cold ms | **Warm ms** | Hits |
|---|---|---|---|
| common "the" | 1,992.7 | **450.0** | 100 |
| rare "xyzorphan" | 133.8 | **130.2** | 2 |
| multi "meeting project" | 951.9 | **944.5** | 100 |
| multi + rare | 590.6 | **595.9** | 100 |
| fetch+fault baseline (no scoring) | 38,858.8 | 38,765.0 | — |

Broad queries went from ~1,912 ms to **450 ms** (4.2x); the rare-term path is
unchanged at ~130 ms, as expected since it takes the direct-fetch branch.
Against the full fetch+fault baseline the rare term is **298x faster**.

**Multi-term queries are now the worst case** (944 ms for two common terms).
Each term runs its own independent `LIKE '%term%'` pass over all 500,000
segments, so scan cost is additive in the number of terms. "multi + rare" is
cheaper (596 ms) because the rare term scans just as hard but returns 2 rows
instead of thousands — the difference is row marshalling, not scanning.
*(That last sentence is an interpretation of the shape, not a separately
measured quantity.)*

The transcript `LIKE` scan is the floor — roughly 400 ms per term at this tier.
No further gain is available without a real index (FTS5), which is deferred.

### Raw SQL reference (segment scan only)

| Tier | rare (warm) | rare (cold) | common "the" (warm) |
|---|---|---|---|
| 50 | **0.9 ms** | 1.6 ms | 2.6 ms |
| 500 | **14.3 ms** | 14.6 ms | 39.3 ms |
| 5000 | **137 ms** | 1,607 ms | 418 ms |

Correctness was verified against the Swift implementation at every tier
(`swift=2 sql=2` for the rare term, including the preferred-transcript filter).

A scan-only variant (no joins) covers 500,000 rows / 284 MB in **257 ms** --
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

1. **Entity numbers in FK column names.** The numeric prefixes in FK column names
   like `Z7SEGMENTS` / `Z4TRANSCRIPTS` are Core Data entity indices (`Z_ENT`)
   that **can shift when the model changes** (adding or removing entities).
   *Resolved:* FK column names are now derived at runtime from Core Data's own
   `Z_PRIMARYKEY` registry and verified against `pragma_table_info` before use
   (`ResolvedSearchSchema` in `SQLiteSegmentSearch.swift`). The naming rule is:
   FK on child = `Z` + parent's `Z_ENT` + parent's relationship name uppercased.
   If resolution fails — missing entity, unexpected inheritance, or a derived
   column absent from the store — the segment contribution is dropped and the
   error is logged (graceful degradation). A gating CI test
   (`SchemaAssertionTests`) asserts that resolution succeeds on a freshly
   generated store, and a differential test compares SQL results against the
   Swift implementation.
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

- At 5000 meetings a single-term search is **130--450 ms warm**, which is fast
  enough to feel responsive. Note that only the rare-term case fits inside the
  300 ms search debounce (`AppCore.setMeetingsQuery`); broad and multi-term
  queries exceed it, so a search can still be in flight when the next one is
  scheduled. That argues for serializing searches, not for adding an index.
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
