# Search Performance -- Validated Findings

## Timeline

| Date | Change |
|---|---|
| 2026-08-25 | Benchmark: linear-scan vs raw SQL (measured) |
| 2026-08-26 | FTS5 side-index implementation; head-to-head benchmark harness added |
| 2026-08-27 | Rebuilt as a single content-storing FTS5 table with `bm25()` ranking; **decision: FTS5 ships**, raw-SQL harness removed |

**Hardware:** Mac16,8 (M4 family), 48 GB RAM, macOS 15.6.1

---

## Decision

**FTS5 ships.** Measured 2026-08-27: on the realistic query (a rare term, which
cannot short-circuit) FTS5 is **0.8 ms at 5000 meetings** against 127 ms for raw
SQL and 38.9 s for the linear scan it replaced. See
[Measured results](#measured-results).

The raw-SQL path was a genuine contender and is described below because the
comparison is the reason FTS5 was chosen. **Its benchmark harness has been
removed** -- it was never shipped, and it depended on undeclared Core Data
column names that would break silently. The measurements it produced are kept
here; the code is not.

---

## The three approaches

The pre-existing shipping code used a **linear scan** -- fetch every `Meeting`,
fault all relationships into memory, and run `localizedStandardContains` per
search term. It is correct and covers every field, but scales badly: **39.5 s
at 5000 meetings** because SwiftData/Core Data object materialization dominates
(string matching is <3% of the cost).

Two replacement candidates were compared:

### Approach A: Raw SQL (LIKE queries against the SwiftData store) -- NOT SHIPPED

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

### Approach B: FTS5 side-index -- SHIPPED

A separate SQLite database (`SearchIndex.sqlite`) holding one FTS5 table
(`meeting_search_index`) with a column per searchable field (title, summary,
notes, transcript, people, tags), plus a `meeting_map` table mapping meeting
UUIDs to the FTS rowid and carrying the effective date. Synced incrementally
via the SwiftData History API.

The table **stores the source text** (it is not contentless). That is what
makes `bm25()` ranking and `snippet()` excerpts possible, and it means a
search result needs no SwiftData fetch at all -- title, date and snippet all
come from this database.

**Strengths:** O(log n) query time instead of O(n). Real relevance ranking via
`bm25()` with per-column weights, so term frequency, term rarity (IDF) and
field length all contribute. One SQL statement per search, with ordering and
`LIMIT` both pushed into SQLite. Prefix + AND semantics. No dependency on
undeclared Core Data internals. Incremental sync re-indexes only changed
meetings.

**Costs:** Extra infrastructure (a second SQLite database, sync machinery,
schema versioning). Stores a second copy of all searchable text, so the index
is far larger than a contentless one. One-time cold reconcile on first launch
or schema bump (seconds, not milliseconds), now also writing that text. No
infix matching (prefix only). Token-based matching changes what search finds
relative to substring matching.

---

## Measured results

Measured **2026-08-27** via `make bench` (`SearchBenchmarkTests.swift`,
env-gated `BISCOTTI_RUN_BENCH=1`), on the hardware named above. Synthetic data:
5000 words of transcript per meeting (100 segments x 50 words). Warm figures
are medians of repeated runs.

Raw-SQL figures come from the same run, taken before that harness was removed.

| Tier | FTS5 cold | FTS5 warm (rare) | FTS5 warm (common) | FTS5 index | SQL warm (rare) | SQL warm (common) | Linear scan |
|---|---|---|---|---|---|---|---|
| 500 | 4,573 ms | **0.7 ms** | 68.4 ms | 21.3 MB | 11.9 ms | 34.1 ms | 3,863 ms |
| 5000 | 51,975 ms | **0.8 ms** | 154.7 ms | 199.4 MB | 127.1 ms | 378.8 ms | 38,863 ms |

**On the realistic query, FTS5 wins decisively and stops scaling.** A rare term
costs 0.7 ms at 500 meetings and 0.8 ms at 5000 -- flat, as an index should be.
Raw SQL is 16x slower at 500 and 163x slower at 5000, because `LIKE` remains a
linear scan. Against the linear scan it replaced, FTS5 is ~48,000x faster at
5000 meetings.

### Three results that need care

**1. Common terms regressed against the previous FTS5 design.** The six-table
contentless build measured 60.5 ms for `"the"` at 5000 meetings; this one
measures **154.7 ms**, with run-to-run spread rising from 3.0 ms to 78.4 ms.
That is despite removing 50 per-hit SwiftData fetches, so the underlying
increase is larger than 2.5x.

The cause is the one flagged in the cost profile below: `bm25()` and `snippet()`
are auxiliary functions evaluated per *matching* row, and `ORDER BY ... LIMIT`
forces SQLite to rank every match before truncating. `"the"` matches all 5000
meetings, so both functions run 5000 times to produce 50 rows. `snippet()` in
particular has to locate term instances in a 5000-word transcript.

This is a real regression, not measurement noise, and the fix is known: a
two-stage query -- inner `SELECT rowid ... ORDER BY bm25(...) LIMIT n`, outer
join computing `snippet()` only for the surviving rowids. **Not yet done.**

It is bounded, though. 154.7 ms is still 15x better than the linear scan's
2,267 ms for the same query, and a common single word is the least valuable
search a user can run.

**2. Cold reconcile did not get worse -- prediction was wrong.** Storing the
source text was expected to slow the full rebuild. It did not: 51,975 ms
against 53,051 ms for the contentless build, i.e. marginally faster and within
noise. Tokenizing dominates; writing the content alongside it is close to free.

52 s at 5000 meetings is still a long time, and it is user-visible on first
launch after a schema bump. It needs a progress indicator (see risks below).
Note it is a *one-time* cost per schema version, not per launch.

**3. Index size is 80-87% of the SwiftData store.** Higher in relative terms
than expected, though the absolute figure (199 MB at 5000 meetings) matched the
estimate. The index holds a second copy of every searchable field, and
transcripts dominate both databases -- hence the ratio.

This is acceptable for this app specifically: it records meeting audio, and
5000 meetings of even well-compressed speech is tens of gigabytes. 199 MB is a
fraction of a percent of that. The ratio would be alarming in an app whose data
was mostly text.

### Incremental sync

| Meetings added | Sync + search |
|---|---|
| +1 | ~20 ms |
| +10 | ~180 ms |
| +50 | ~890 ms |

About **18 ms per meeting re-indexed**, flat across both tiers -- it depends on
the changed set, not the corpus size, which is the property incremental sync
exists to provide. Bulk operations pay for it: re-transcribing 50 meetings adds
roughly 0.9 s of index work.

### FTS5 cost profiles

- **Cold (full reconcile):** First search on a fresh index -- builds the entire
  FTS5 index from scratch, then runs the query. User-visible on first launch
  after update.
- **Warm:** Index up to date, history token current. The common path. The
  measurement runs the full production `searchHits()` call: a SwiftData
  history check (no-op when current), a count-based staleness check
  (`indexedMeetingCount` vs SwiftData `fetchCount` -- two cheap counts,
  triggers a full reconcile on mismatch), then **one** SQL statement --
  a single FTS5 MATCH joined to `meeting_map`, computing `bm25()` and
  `snippet()`, ordered by `(rank, effective date desc, UUID)` with
  `LIMIT` applied by SQLite. **No SwiftData fetch per hit:** title, date
  and snippet all come from the side DB.
  - `bm25()` and `snippet()` are auxiliary functions evaluated per matching
    row, and `ORDER BY ... LIMIT` forces SQLite to rank every match before
    truncating. A common term therefore pays them over the whole match set,
    not just the 50 survivors. **Measured, and it matters** -- see result 1
    above.
- **Incremental:** Sync + search after +1 / +10 / +50 meetings were added.
- **Index size:** On-disk bytes of `SearchIndex.sqlite` (plus its WAL) after
  the cold reconcile, reported next to the SwiftData store size. This is the
  cost of storing the text.

---

## Linear-scan measurements (superseded implementation, 2026-08-25)

These are the numbers that justified building an index at all. The old
`searchHits` fetched **every** `Meeting`, then walked relationships in memory --
participants, tags, transcripts, and every transcript segment -- running
`localizedStandardContains` per term. Kept as the baseline the current
implementation is measured against.

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

> **Reference only -- nothing in the shipping code depends on this.** It was
> established for the raw-SQL approach, which was not shipped and whose harness
> has been removed. Kept because it cost real work to derive and is the map
> anyone would need before reading the SwiftData file directly again. The
> fragility described under "Raw-SQL risks" is exactly why the FTS5 index owns
> its own storage instead.

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

### The validated query (used by the removed raw-SQL harness)

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

### Raw-SQL risks (why it was not shipped)

These applied to the raw-SQL approach only. No shipping code carries them --
they are recorded because risk 1 is the main reason FTS5 was preferred even
before the numbers were in.

1. **Entity numbers in FK column names.** The `7` and `4` in `Z7SEGMENTS` /
   `Z4TRANSCRIPTS` are Core Data entity indices and **can shift when the model
   changes** (adding or removing entities). Failure is **silent** -- zero results,
   no error. Mitigating it would have meant resolving column names at runtime via
   `PRAGMA table_info`, asserting the schema shape in a test, and maintaining a
   differential test against the Swift implementation -- ongoing cost for a path
   that lost on speed anyway.
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
   re-indexes every meeting. **Measured at 52 s for 5000 meetings** (4.6 s at
   500). *Mitigate:* show a progress indicator -- at this magnitude it is not
   optional. The cost is one-time per schema version, not per launch.
2. **History token expiry.** If SwiftData history transactions expire before the
   next search, incremental sync fails and falls back to full reconcile. Normal
   usage (search at least once per session) keeps the token fresh.
3. **Index size.** The FTS5 table stores the source text (required for
   `snippet()`), so the index holds a second copy of every searchable field --
   transcripts dominate. **Measured at 80-87% of the SwiftData store**
   (199 MB at 5000 meetings). *Mitigate:* it is still a fraction of a percent
   of the recorded audio. Re-check this if the app ever stores substantially
   more text per meeting.
4. **No infix matching.** FTS5 matches whole words and prefixes, not arbitrary
   substrings. `"roa"` matches "roadmap" but `"oadm"` does not. This is a
   **product-level change** in what search finds relative to substring matching.
5. **Complexity.** A second SQLite database, a sync engine using the History API,
   schema versioning, and rollback logic -- all machinery that raw SQL does not
   require.
6. **Common-term latency scales with the match set, not the result set.**
   `bm25()` and `snippet()` are evaluated per matching row before `LIMIT`
   applies. **Measured at 154.7 ms for `"the"` at 5000 meetings**, a regression
   against the earlier contentless design. *Mitigate (not yet done):* a
   two-stage query computing `snippet()` only for the surviving rowids.

---

## Reproducing

```
make bench        # NON-GATING, ~12 min, generates multi-GB stores
```

Runs `SearchBenchmarkTests.swift`, env-gated on `BISCOTTI_RUN_BENCH=1` so it
never runs in `make test` / `make ci` / `make precommit-checks`. Reports FTS5
cold, warm, incremental and index size, plus the linear-scan fetch+fault
baseline.

A fast smoke test (5 meetings, ~30 ms) **does** run in `make test` to catch rot
in the generator and measurement harness.

All benchmarks use **generated data only** and never touch the real store.
