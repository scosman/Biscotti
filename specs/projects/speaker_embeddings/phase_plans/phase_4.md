---
status: complete
---

# Phase 4: VoiceprintMatching Module

## Overview

Build the new `VoiceprintMatching` module in BiscottiKit. This is a pure-logic module that depends only on `DataStore` (for its DTO types) and uses `Accelerate` for vector math. It contains: configuration, vector math, prepared corpus, the matcher and explain, backfill speaker mapping, the evaluator, and the metrics formatter. All public types are `Sendable`. The module is fully unit-testable with synthetic vectors.

## Steps

1. Add `VoiceprintMatching` target and `VoiceprintMatchingTests` test target to `Packages/BiscottiKit/Package.swift`. The target depends on `DataStore`. Mark it as a library product.

2. Create `Sources/VoiceprintMatching/VoiceprintConfig.swift`:
   - `KindThresholds` struct with `acceptRadius`, `highDistance`, `mediumDistance`.
   - `VoiceprintConfig` struct with all constants from architecture section 5.1.
   - `thresholds(for:)` method, `default` static.

3. Create `Sources/VoiceprintMatching/VectorMath.swift`:
   - `normalized(_:)` returning `[Float]?` (nil for empty, NaN, zero norm).
   - `distance(_:_:)` using `vDSP_dotpr` for cosine distance on normalized vectors.

4. Create `Sources/VoiceprintMatching/PreparedCorpus.swift`:
   - `HistoryStats` and `PersonHistory` structs.
   - `PreparedCorpus` struct that normalizes entries, drops failures and dimension mismatches, computes `HistoryStats`.
   - `excluding(meetingID:)` method for the evaluator.

5. Create `Sources/VoiceprintMatching/VoiceprintMatcher.swift`:
   - `MatchLevel` enum (high, medium, low, ambiguous, none) with `CodingKeyRepresentable`.
   - `PersonCandidate`, `SpeakerMatch`, `Invitees`, `SpeakerExplanation`, `NearestVoiceprint` structs.
   - `VoiceprintMatcher` struct with `match(query:corpus:invitees:)` and `explain(vector:speakerID:corpus:invitees:nearestCount:)`.
   - Shared internal `score(...)` function between match and explain.

6. Create `Sources/VoiceprintMatching/BackfillSpeakerMapper.swift`:
   - `SpeakerSpan` struct.
   - `BackfillSpeakerMapper` enum with `map(fresh:stored:minOverlapFraction:)`.
   - Greedy one-to-one overlap matching algorithm.

7. Create `Sources/VoiceprintMatching/VoiceprintEvaluator.swift`:
   - `VoiceprintMetrics` with `LevelStats`, `SweepRow`, `ConfusedPair`, `SuspectTag`, `Coverage`.
   - `VoiceprintEvaluator` struct with `evaluate(_:)` using leave-one-meeting-out.
   - DET sweep and EER calculation.

8. Create `Sources/VoiceprintMatching/MetricsFormatter.swift`:
   - `MetricsFormatter.text(_:includeSweep:)` rendering one section per kind with a summary header.

9. Write comprehensive tests in `Tests/VoiceprintMatchingTests/VoiceprintMatchingTests.swift`:
   - `VectorMath`: normalization, zero/NaN/empty rejection, distance range and clamp.
   - Matcher: all level boundaries, ambiguity triggers, invitee boost, best-K cap, one-vote-per-meeting, unnamed count, dimension mismatch, tie-break, per-kind thresholds.
   - `explain`: match consistency, nearest includes outside R, allCandidates not truncated.
   - `BackfillSpeakerMapper`: identity, renumbered, overlap threshold, greedy conflict.
   - `VoiceprintEvaluator`: leakage test, sweep rates, EER, confused pairs, suspect tags, trials without history.
   - `MetricsFormatter`: golden text for a small two-kind result.

## Tests

- `testNormalization`: unit vector output, magnitude 1
- `testNormalizationRejectsZero`: zero vector returns nil
- `testNormalizationRejectsNaN`: NaN vector returns nil
- `testNormalizationRejectsEmpty`: empty vector returns nil
- `testDistanceIdentical`: distance of identical vectors is 0
- `testDistanceOrthogonal`: distance of orthogonal vectors is 1
- `testDistanceOpposite`: distance of opposite vectors is 2
- `testDistanceClamp`: result stays in [0, 2]
- `testMatchNone`: no voiceprint inside R gives .none
- `testMatchHigh`: high confidence level boundaries
- `testMatchMedium`: medium level boundaries
- `testMatchLow`: low level default
- `testMatchAmbiguousScoreRatio`: ambiguity via score ratio
- `testMatchAmbiguousDistanceGap`: ambiguity via distance gap
- `testMatchAmbiguousCap`: max candidates capped
- `testOneVotePerMeeting`: deduplicated by meeting
- `testBestKCap`: best-K meetings cap
- `testInferredTagWeight`: confirmed outweighs inferred
- `testSpeechWeightShort`: short speech weighs less
- `testInviteeBoost`: invitee boost changes the winner
- `testUnnamedCount`: unnamed meetings counted, deduplicated
- `testDimensionMismatch`: dimension mismatch gives .none
- `testDeterministicTieBreak`: stable ordering on ties
- `testPerKindThresholds`: raw vs plda thresholds used
- `testExplainMatchConsistency`: explain.match equals match() result
- `testExplainNearestOutsideR`: nearest includes entries outside R
- `testExplainAllCandidatesNotTruncated`: allCandidates is complete
- `testBackfillIdentity`: same speaker IDs map 1:1
- `testBackfillRenumbered`: different IDs map by overlap
- `testBackfillBelowThreshold`: low overlap is unmapped
- `testBackfillGreedyConflict`: greedy one-to-one resolution
- `testEvaluatorLeakage`: own-meeting voiceprints hidden
- `testEvaluatorSweep`: sweep rates on hand-computed corpus
- `testEvaluatorEER`: EER choice
- `testEvaluatorConfusedPairs`: confused pairs populated
- `testEvaluatorSuspectTags`: suspect tags populated
- `testEvaluatorTrialsWithoutHistory`: trials without history counted
- `testMetricsFormatterGolden`: golden text comparison
