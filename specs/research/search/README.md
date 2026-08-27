# Search Performance -- Validated Findings

## Timeline

| Date | Change |
|---|---|
| 2026-08-25 | Benchmark: linear-scan vs raw SQL (measured) |
| 2026-08-26 | FTS5 side-index implementation; head-to-head benchmark harness added |

**Hardware:** Mac16,8 (M4 family), 48 GB RAM, macOS 15.6.1

---

## The three approaches

The current shipping code uses a **linear scan** -- fetch every `Meeting`,
fault all relationships into memory, and run `localizedStandardContains` per
search term. It is correct and covers every field, but scales badly: **39.5 s
at 5000 meetings** because SwiftData/Core Data object materialization dominates
(string matching is <3% of the cost).

This branch compares two replacement candidates:

### Approach A: Raw SQL (LIKE queries against the SwiftData store)

Query the SwiftData SQLite file directly with a read-only connection, using
`LIKE '%term%'` on the segment text column. Joins through the existing Core Data
foreign keys to resolve segment -> transcript -> meeting.

**Strengths:** No new infrastructure, no index to build or maintain, no data
duplication. The foreign keys already exist in the store. 288x faster than the
linear scan at 5000 meetings (137 ms warm).

**Costs:** Still linear (`LIKE` cannot use an index). Relies on undeclared Core
Data foreign key column names (`Z7SEGMENTS`, `Z4TRANSCRIPTS`) that can shift
silently when the model changes. Case-insensitive for ASCII only, no diacritic
folding. Cold cost is real (page-cache misses on first query).

### Approach B: FTS5 side-index

A separate SQLite database (`SearchIndex.sqlite`) with contentless FTS5 tables
for each searchable field (title, summary, notes, transcript, people, tags).
Synced incrementally via the SwiftData History API.

**Strengths:** O(log n) query time instead of O(n). Per-field weighted scoring
with prefix + AND semantics. No dependency on undeclared Core Data internals.
Incremental sync means only changed meetings are re-indexed.

**Costs:** Extra infrastructure (a second SQLite database, sync machinery,
schema versioning). One-time cold reconcile on first launch or schema bump
(seconds, not milliseconds). No infix matching (prefix only). Token-based
matching changes what search finds relative to substring matching.

---

## Head-to-head benchmark results

**Not yet run.** The benchmark harness is in place
(`SearchBenchmarkTests.swift`, env-gated `BISCOTTI_RUN_BENCH=1`) and ready to
run via `make bench`. Both approaches are measured against the **same generated
datasets** at the same meeting counts (50 / 500 / 5000), with the same queries
(including the rare-term query -- the realistic case that cannot short-circuit).

Results will be recorded here after a human runs the suite on hardware.

### FTS5 cost profiles

- **Cold (full reconcile):** First search on a fresh index -- builds the entire
  FTS5 index from scratch, then runs the query. User-visible on first launch
  after update.
- **Warm:** Index up to date, history token current. The common path. The
  measurement runs the full production `searchHits()` call: a SwiftData
  history check (no-op when current), a count-based staleness check
  (`indexedMeetingCount` vs SwiftData `fetchCount` -- two cheap counts,
  triggers a full reconcile on mismatch), 6 FTS5 MATCH queries per term
  (one per indexed field), rowid-to-UUID resolution, then a SwiftData
  fetch per hit (up to 50) for title display data. The effective date
  used for ordering comes from the side DB (carried on `RawHit`), not
  from the SwiftData fetch.
- **Incremental:** Sync + search after +1 / +10 / +50 meetings were added.

### Raw SQL cost profiles

- **Cold:** First query against the SwiftData store (page-cache cold).
- **Warm:** Subsequent queries with pages in cache. The measurement runs a
  `SELECT DISTINCT hex(m.ZID) ... WHERE LIKE '%term%'` scan with joins,
  fetching the UUIDs of matching meetings (not just a count). This is the
  SQL scan + result materialization, but does not include SwiftData object
  resolution for display data (title/date). FTS5 warm does include that
  resolution step; for the rare-term query (typically 2 hits) the overhead
  is negligible, but for common terms (many hits) it adds measurable cost
  to FTS5's side of the comparison.

### Expected result template (to be filled with real measurements)

| Tier | FTS5 cold | FTS5 warm (rare) | FTS5 warm (common) | SQL cold (rare) | SQL warm (rare) | SQL warm (common) |
|---|---|---|---|---|---|---|
| 50 | ? ms | ? ms | ? ms | ? ms | ? ms | ? ms |
| 500 | ? ms | ? ms | ? ms | ? ms | ? ms | ? ms |
| 5000 | ? ms | ? ms | ? ms | ? ms | ? ms | ? ms |

---

## Linear-scan measurements (current shipping code, 2026-08-25)

The current `searchHits` fetches **every** `Meeting`, then walks relationships
in memory -- participants, tags, transcripts, and every transcript segment --
running `localizedStandardContains` per term.

The cost was **SwiftData/Core Data faulting**, not string matching. At 5000
meetings it materialized ~500,000 segment objects. String matching was only
**2--3%** of the total. A **rare** term (a name, a project -- the realistic user
query) was the worst case: no short-circuit possible.

Synthetic data: 5000 words of transcript per meeting (100 segments x 50 words).
Median of 3 warm runs.

| Tier | common "the" | **rare term** | multi-term | fetch+fault only |
|---|---|---|---|---|
| 50 | 20.2 ms | **384.6 ms** | 39.2 ms | 375.8 ms |
| 500 | 203.9 ms | **3,829 ms** | 390.2 ms | 3,732 ms |
| 5000 | 2,267 ms | **39,479 ms** | 3,990 ms | 38,101 ms |

### Raw SQL against the same stores (same run)

| Tier | rare (warm) | rare (cold) | common "the" (warm) |
|---|---|---|---|
| 50 | **0.9 ms** | 1.6 ms | 2.6 ms |
| 500 | **14.3 ms** | 14.6 ms | 39.3 ms |
| 5000 | **137 ms** | 1,607 ms | 418 ms |

| Tier | rare speedup (vs linear-scan) | common speedup |
|---|---|---|
| 50 | 428x | 7.8x |
| 500 | 268x | 5.2x |
| 5000 | **288x** | 5.4x |

A scan-only variant (no joins) covered 500,000 rows / 284 MB in **257 ms** --
roughly 1.1 GB/s. The joins were nearly free (137 ms vs 142 ms scan-only). The
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
| `ZTRANSCRIPTRECORD` | `Z_PK`, `ZID`, **`Z4TRANSCRIPTS`** -> FK to `ZMEETING.Z_PK` |
| `ZTRANSCRIPTSEGMENTRECORD` | `Z_PK`, `ZTEXT`, **`Z7SEGMENTS`** -> FK to `ZTRANSCRIPTRECORD.Z_PK` |

**The parent foreign keys already exist**, even though the Swift models declare no
inverse relationship. Core Data names an undeclared-inverse FK
`Z<entityNumber><parentRelationshipName>`. This is why raw SQL needs no schema
change, but is fragile -- entity numbers can shift when the model changes.

`ZID` is a 16-byte **BLOB**, so use `hex(ZID)` to read UUIDs as text.

### The validated query (used by both RawSQLSanityCheckTests and the benchmark)

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

### Raw-SQL risks

1. **Entity numbers in FK column names.** The `7` and `4` in `Z7SEGMENTS` /
   `Z4TRANSCRIPTS` are Core Data entity indices and **can shift when the model
   changes** (adding or removing entities). Failure is **silent** -- zero results,
   no error. *Mitigate:* resolve column names at runtime via `PRAGMA table_info`,
   assert the expected schema shape in a test, and keep a differential test
   comparing SQL results against the Swift implementation.
2. **The store format is private and undocumented.** Apple does not support
   reading it directly. In practice it is stable, but treat it as read-only --
   never write through this path.
3. **`LIKE` semantics differ from `localizedStandardContains`.** SQLite's `LIKE`
   is case-insensitive for ASCII only and does no diacritic folding, so "cafe"
   stops matching "cafe". A deliberate product call.
4. **Cold cost is real.** 1,607 ms cold vs 137 ms warm at 5000 meetings -- the
   first search after launch pays page-cache misses.
5. **Unsaved SwiftData changes are invisible** to a separate connection. Ensure
   writes are saved before searching.
6. **Still linear.** `LIKE '%term%'` cannot use an index. This buys a large
   constant-factor win, not a better curve -- fine at 5k--20k meetings, not at
   100k.

### FTS5 side-index risks

1. **Cold reconcile latency.** The first search after a schema version bump
   re-indexes every meeting. At 5000 meetings this will be measurable (seconds,
   not milliseconds). *Mitigate:* show a progress indicator; the cost is one-time.
2. **History token expiry.** If SwiftData history transactions expire before the
   next search, incremental sync fails and falls back to full reconcile. Normal
   usage (search at least once per session) keeps the token fresh.
3. **Index size.** Contentless FTS5 stores only the reverse index and row IDs,
   not the source text. Index size is much smaller than the main store.
4. **No infix matching.** FTS5 matches whole words and prefixes, not arbitrary
   substrings. `"roa"` matches "roadmap" but `"oadm"` does not. This is a
   **product-level change** in what search finds relative to substring matching.
5. **Complexity.** A second SQLite database, a sync engine using the History API,
   schema versioning, and rollback logic -- all machinery that raw SQL does not
   require.

---

## Reproducing

```
make bench        # NON-GATING, ~12 min, generates multi-GB stores
```

Runs all benchmark suites, each env-gated so they never run in `make test` /
`make ci` / `make precommit-checks`:

- `SearchBenchmarkTests.swift` -- `BISCOTTI_RUN_BENCH=1`, head-to-head FTS5 vs
  raw SQL (same data, same queries, same run)
- `RawSQLSanityCheckTests.swift` -- `BISCOTTI_RUN_SQLCHECK=1`, standalone
  raw-SQL timing + schema dump

A fast smoke test (5 meetings, ~30 ms) **does** run in `make test` to catch rot
in both the FTS5 and raw-SQL measurement harnesses.

All benchmarks use **generated data only** and never touch the real store.
