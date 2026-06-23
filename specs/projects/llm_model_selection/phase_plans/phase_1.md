---
status: complete
---

# Phase 1: LocalLLM Catalog + Inventory (+ E2B Manual Test)

## Overview

Adds the model catalog (`LLMModel` + `LLMModelCatalog`) and disk inventory (`ModelInventory`) to the
`LocalLLM` package, providing the multi-model data model and the "list/check/delete downloaded
models" capability. Also extends the ManualTestApp Local LLM tab with E2B-specific coverage (download
+ multi-turn KV-cache reuse inference on E2B through BiscottiLLM.xpc). Existing `llm_*` manual-test
steps are marked `not-run` per the staleness rule.

## Steps

1. **Create `LLMModel.swift`** in `Packages/LocalLLM/Sources/LocalLLM/`:
   - `public struct LLMModel: Sendable, Equatable, Identifiable` with fields: `id: String`,
     `displayName: String`, `downloadURL: URL`, `fileName: String`, `approxDownloadBytes: Int64`.
   - `public enum LLMModelCatalog` with:
     - `public static let all: [LLMModel]` containing the 12B and E2B descriptors (in display order).
     - `public static func model(id: String) -> LLMModel?` for lookup.

2. **Create `ModelInventory.swift`** in `Packages/LocalLLM/Sources/LocalLLM/`:
   - `public struct ModelInventory: Sendable` with `init(cacheDirectory: URL)`.
   - `public func path(for model: LLMModel) -> URL` (cacheDirectory + model.fileName).
   - `public func isDownloaded(_ model: LLMModel) -> Bool` (delegates to
     `ModelDownloader.fileExistsAndNonEmpty`).
   - `public func downloadedModels(in catalog: [LLMModel]) -> [LLMModel]` (filters by isDownloaded).
   - `public func delete(_ model: LLMModel) throws` (removes file + sibling `.partial`).

3. **Extend LocalLLMScript.swift** with three new E2B steps appended before the reclamation check:
   - `.action(id: "llm_e2b_download", ...)` -- download the E2B model.
   - `.action(id: "llm_e2b_kv_reuse", ...)` -- multi-turn KV-cache reuse inference on E2B through
     BiscottiLLM.xpc.
   - `.humanQuestion(id: "llm_e2b_kv_reuse_quality", ...)` -- observation.

4. **Wire E2B steps in WiredScripts.swift**: add cases for `llm_e2b_download` (download from E2B
   catalog entry's URL) and `llm_e2b_kv_reuse` (connect to BiscottiLLM.xpc with the E2B model path,
   run two extending generates for KV-cache reuse validation).

5. **Update `manual_test_results.json`**: mark all existing `llm_*` recordable steps as `not-run`;
   add `llm_e2b_download`, `llm_e2b_kv_reuse`, `llm_e2b_kv_reuse_quality` as `not-run`.

6. **Update ScriptShapeTests.swift**: bump Local LLM step count to 24 (21 + 3 new); add the three
   new step IDs to the canonical set.

## Tests

- `LLMModelCatalogTests`: catalog `all` has exactly 2 models; IDs are distinct and non-empty;
  `model(id:)` returns the correct entry; `model(id:)` returns nil for unknown ID; URLs are distinct
  and well-formed; filenames are distinct and non-empty; `approxDownloadBytes` > 0 for each.
- `ModelInventoryTests`: `path(for:)` composes cacheDirectory + fileName; `isDownloaded` true for
  non-empty file, false for missing/empty/directory; `downloadedModels(in:)` filtering works;
  `delete` removes the file and its `.partial` sibling; `delete` of a missing file does not throw.
- `ScriptShapeTests` (updated): Local LLM step count = 24, IDs include the 3 new E2B steps.
