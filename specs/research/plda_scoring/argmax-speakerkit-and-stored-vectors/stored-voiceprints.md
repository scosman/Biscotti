# Stored Voiceprints: Schema, Encoding, and Structure

How Biscotti persists voiceprints in the SwiftData/SQLite store, and what a
benchmark needs to read them.

---

## SQLite schema

Store path: `~/Library/Application Support/Biscotti/Biscotti.store`

### ZVOICEPRINT table

| Column | SQLite type | Content |
|---|---|---|
| `Z_PK` | INTEGER | SwiftData auto-increment primary key |
| `Z_ENT`, `Z_OPT` | INTEGER | SwiftData internal entity/optimistic-lock |
| `ZSPEAKERID` | INTEGER | Diarization speaker ID within the owning transcript (0-based) |
| `ZKINDRAW` | VARCHAR | `"raw"` or `"plda"` |
| `ZEMBEDDINGSPACE` | VARCHAR | `"pyannote-v3/W8A16"` (raw) or `"pyannote-v3/W8A16+plda:pyannote-v4/W32A32"` (plda) |
| `ZDIMENSION` | INTEGER | 256 (raw) or 128 (plda) |
| `ZVECTORDATA` | BLOB | Little-endian Float32 values (1024 bytes for raw, 512 bytes for plda) |
| `ZSPEAKINGDURATION` | FLOAT | Seconds of the speaker's diarization time in this meeting |
| `ZTRANSCRIPT` | INTEGER | FK to `ZTRANSCRIPTRECORD.Z_PK` |
| `ZCREATEDAT` | TIMESTAMP | Row creation timestamp |
| `ZID` | BLOB | UUID (16 bytes, binary) |

### ZPERSON table

| Column | Type | Content |
|---|---|---|
| `Z_PK` | INTEGER | Primary key |
| `ZNAME` | VARCHAR | Display name |
| `ZEMAIL` | VARCHAR | Email (nullable; used for dedup) |
| `ZID` | BLOB | UUID |

### Speaker assignments (voiceprint-to-person link)

Speaker assignments live as **JSON-encoded Data** in
`ZTRANSCRIPTRECORD.speakerAssignmentsData` (a private SwiftData field). The
JSON shape is `{speakerID: {personID: uuid, userSet: bool}}`.

There is no separate join table for voiceprint-to-person. The link is:
```
ZVOICEPRINT.ZTRANSCRIPT -> ZTRANSCRIPTRECORD.Z_PK
ZTRANSCRIPTRECORD.speakerAssignmentsData[voiceprint.ZSPEAKERID] -> personID
ZPERSON.ZID = personID
```

The `speakerAssignmentsData` column is not directly named in the SQLite schema
(SwiftData maps private stored properties). To find it:

```sql
-- The column is in ZTRANSCRIPTRECORD; look for a BLOB/VARCHAR column
-- containing JSON like {"0":{"personID":"...","userSet":true}}
-- Its SwiftData-generated column name may differ from the Swift property name.
```

In practice, the `voiceprint-cli` and `DataStore.voiceprintCorpus()` read this
through the SwiftData API, not raw SQL.

### ZTAG table (not used for voiceprints)

Tags (`ZTAG`) are for meeting-level labels (e.g. team, project), not speaker
identity. Speaker identity goes through `speakerAssignments`.

---

## Vector encoding

`VectorCoding` (DataStore/VectorCoding.swift) encodes `[Float]` as raw bytes:

```swift
// Encode: direct copy of Float32 buffer to Data
vector.withUnsafeBufferPointer { buffer in Data(buffer: buffer) }

// Decode: bind Data bytes as Float32 array
data.withUnsafeBytes { raw in Array(raw.bindMemory(to: Float.self)) }
```

Little-endian Float32, which is native on Apple Silicon. No header, no
compression, no normalization. The stored vectors are **raw (unnormalized)
centroid means**, exactly as returned by `centroidsFromFinalAssignments`.

### Python decode

```python
import struct
import numpy as np

def decode_vector(blob: bytes, dim: int) -> np.ndarray:
    """Decode a ZVECTORDATA blob to a numpy array."""
    assert len(blob) == dim * 4
    return np.frombuffer(blob, dtype='<f4')  # little-endian float32
```

---

## Current store statistics

(From a read-only snapshot taken 2026-10-07)

| Metric | Value |
|---|---|
| Voiceprints per kind | 367 |
| Total voiceprints | 734 |
| Transcripts with voiceprints | 135 |
| Persons | 89 |
| Raw dimension | 256 |
| PLDA dimension | 128 |
| Raw space | `pyannote-v3/W8A16` |
| PLDA space | `pyannote-v3/W8A16+plda:pyannote-v4/W32A32` |
| Avg speaking duration | ~392 seconds |

---

## What is NOT stored

- **Window/segment count**: no field for how many per-window embeddings were
  averaged into the centroid. Only `speakingDuration` is stored. For the LLR
  formula that needs N (number of enrollment samples), estimate from duration:
  ~1 window per second (10 s windows with ~1 s stride, but only active windows).
- **Per-window embeddings**: only the centroid mean is stored. Individual window
  embeddings exist only transiently in memory during diarization.
- **L2 norm of original centroid**: the stored vector IS the original
  unnormalized centroid. The `PreparedCorpus` L2-normalizes at query time.

---

## Embedding space versioning

Each voiceprint carries an `embeddingSpace` string that identifies the models
that produced it (`SpeakerEmbeddingSpace.swift`):

- Raw: `"<embedder_version>/<embedder_variant>"` -- e.g. `"pyannote-v3/W8A16"`
- PLDA: `"<embedder>+plda:<plda_version>/<plda_variant>"` -- e.g.
  `"pyannote-v3/W8A16+plda:pyannote-v4/W32A32"`

Corpus queries filter by kind AND space, so voiceprints from different model
versions are never compared.

---

## Sources

- `Voiceprint.swift` (SwiftData model)
  Path: `Packages/BiscottiKit/Sources/DataStore/Models/Voiceprint.swift`
- `VectorCoding.swift` (encode/decode)
  Path: `Packages/BiscottiKit/Sources/DataStore/VectorCoding.swift`
- `DataStore+Voiceprints.swift` (queries)
  Path: `Packages/BiscottiKit/Sources/DataStore/DataStore+Voiceprints.swift`
- `SpeakerEmbeddingSpace.swift` (space key construction)
  Path: `Packages/Transcription/Sources/Transcription/SpeakerEmbeddingSpace.swift`
- `TranscriptRecord.swift` lines 10-70 (speaker assignments)
  Path: `Packages/BiscottiKit/Sources/DataStore/Models/TranscriptRecord.swift`
- SQLite snapshot query results (2026-10-07)
