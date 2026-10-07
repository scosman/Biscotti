#!/usr/bin/env python3
"""
PLDA LLR benchmark: compares raw cosine, PLDA cosine, and PLDA LLR scoring
for voiceprint matching on the Biscotti store.

Uses leave-one-meeting-out cross-validation, matching the protocol of the
Swift voiceprint-cli metrics evaluator (trials-without-history are skipped).

Usage:
    uv run --with numpy Tools/plda_benchmark.py [--db PATH] [--self-test]

The default DB path is $TMPDIR/biscotti_benchmark.db.  To create that snapshot:
    sqlite3 "file:$HOME/Library/Application Support/Biscotti/Biscotti.store?mode=ro" \
      ".backup '$TMPDIR/biscotti_benchmark.db'"
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sqlite3
import sys
from dataclasses import dataclass, field

import numpy as np

# ---------------------------------------------------------------------------
# Phi: between-class covariance eigenvalues from argmax SpeakerKit.
# Source: argmax-oss-swift, revision 0475cca, branch biscotti/v1.1.0-plda-centroids
# File: Sources/SpeakerKit/Pyannote/ClusteringAlgorithms.swift, lines 532-559
# Copied verbatim -- private static let betweenClassCovariance.
# ---------------------------------------------------------------------------
PHI = np.array(
    [
        25.8823843, 10.64654768, 7.09749664, 5.70842102, 5.27071843,
        4.99630206, 4.25741596, 4.07776313, 3.89517645, 3.69594798,
        3.64910204, 3.4740059,  3.1161406,  2.89308777, 2.85235283,
        2.74298281, 2.69856644, 2.54895349, 2.49312298, 2.35923547,
        2.31617442, 2.25039797, 2.20650582, 2.11553732, 2.08046971,
        2.04438817, 1.99983924, 1.94495688, 1.90123046, 1.86979365,
        1.84888933, 1.81611504, 1.76659227, 1.73939854, 1.71681168,
        1.68313843, 1.63579985, 1.6291736,  1.58139228, 1.53777309,
        1.52376318, 1.50576921, 1.4852546,  1.46273286, 1.46112849,
        1.43902254, 1.41162633, 1.40358761, 1.38767215, 1.35415771,
        1.34320055, 1.31804126, 1.29211534, 1.26927315, 1.25277974,
        1.23694313, 1.21484673, 1.21013266, 1.20138393, 1.19199542,
        1.17204403, 1.14954023, 1.14245929, 1.122949,   1.11425141,
        1.09640355, 1.08456146, 1.0667317,  1.05513591, 1.04003146,
        1.02566902, 1.02010552, 1.01099642, 0.99231797, 0.98069675,
        0.97343907, 0.95881054, 0.95197792, 0.9462381,  0.92696959,
        0.91914417, 0.9136186,  0.90647712, 0.90414186, 0.8860543,
        0.88015839, 0.87319719, 0.86870833, 0.86731253, 0.85900931,
        0.84836197, 0.83159452, 0.82433101, 0.81734176, 0.80188412,
        0.79747487, 0.79064521, 0.78698437, 0.78016046, 0.76995838,
        0.76739477, 0.76181261, 0.7557517,  0.74880944, 0.73518941,
        0.73211398, 0.7256853,  0.72203483, 0.70633259, 0.70241969,
        0.69792648, 0.68882402, 0.67445369, 0.67196181, 0.66614225,
        0.65970189, 0.65231306, 0.6459088,  0.64389891, 0.63339111,
        0.62995437, 0.62304199, 0.61221797, 0.61031214, 0.60488038,
        0.6014566,  0.58401099, 0.56960536,
    ],
    dtype=np.float64,
)

# ---------------------------------------------------------------------------
# Known same-person aliases (from calibration.md and data inspection).
# Each group is a set of person names/emails that refer to the same human.
# ---------------------------------------------------------------------------
SAME_PERSON_GROUPS: list[list[str]] = [
    ["Steve", "scosman@gmail.com", "steve@getkiln.ai"],  # user's own emails are fine
    ["Sam"],
    ["Ellen"],
    ["Leonard", "Leon"],
    ["Mike", "Mike Chat"],
    ["Daniel"],
]

# ---------------------------------------------------------------------------
# Data loading
# ---------------------------------------------------------------------------


@dataclass
class PersonRecord:
    pk: int
    name: str
    email: str | None
    uuid_hex: str  # uppercase hex of the 16-byte UUID blob


@dataclass
class VoiceprintEntry:
    meeting_pk: int
    meeting_id_hex: str
    transcript_pk: int
    speaker_id: int
    kind: str  # "raw" or "plda"
    dimension: int
    vector: np.ndarray
    speaking_duration: float
    person_uuid_hex: str | None  # from speaker assignments
    user_set: bool  # tag provenance


def load_persons(conn: sqlite3.Connection) -> dict[str, PersonRecord]:
    """Returns {uuid_hex: PersonRecord}."""
    rows = conn.execute(
        "SELECT Z_PK, ZNAME, ZEMAIL, hex(ZID) FROM ZPERSON"
    ).fetchall()
    persons: dict[str, PersonRecord] = {}
    for pk, name, email, uid_hex in rows:
        persons[uid_hex.upper()] = PersonRecord(
            pk=pk, name=name or "", email=email, uuid_hex=uid_hex.upper()
        )
    return persons


def load_voiceprints(conn: sqlite3.Connection) -> list[VoiceprintEntry]:
    """Load all voiceprints with meeting context and speaker assignments."""
    rows = conn.execute(
        """
        SELECT
            m.Z_PK, hex(m.ZID),
            t.Z_PK, t.ZSPEAKERASSIGNMENTSDATA,
            v.ZSPEAKERID, v.ZKINDRAW, v.ZDIMENSION, v.ZVECTORDATA, v.ZSPEAKINGDURATION
        FROM ZVOICEPRINT v
        JOIN ZTRANSCRIPTRECORD t ON v.ZTRANSCRIPT = t.Z_PK
        JOIN ZMEETING m ON t.Z4TRANSCRIPTS = m.Z_PK AND m.ZPREFERREDTRANSCRIPTID = t.ZID
        ORDER BY m.Z_PK, v.ZKINDRAW, v.ZSPEAKERID
        """
    ).fetchall()

    entries: list[VoiceprintEntry] = []
    for (
        m_pk, m_id_hex,
        t_pk, assignments_blob,
        speaker_id, kind, dim, vec_blob, speaking_dur,
    ) in rows:
        vec = np.frombuffer(vec_blob, dtype="<f4").astype(np.float64)
        if len(vec) != dim:
            continue

        person_uuid_hex: str | None = None
        user_set = False
        if assignments_blob and len(assignments_blob) > 2:
            try:
                assignments = json.loads(assignments_blob)
                key = str(speaker_id)
                if key in assignments:
                    person_uuid_hex = assignments[key]["personID"].replace("-", "").upper()
                    user_set = assignments[key].get("userSet", False)
            except (json.JSONDecodeError, KeyError):
                pass

        entries.append(
            VoiceprintEntry(
                meeting_pk=m_pk,
                meeting_id_hex=m_id_hex,
                transcript_pk=t_pk,
                speaker_id=speaker_id,
                kind=kind,
                dimension=dim,
                vector=vec,
                speaking_duration=speaking_dur or 0.0,
                person_uuid_hex=person_uuid_hex,
                user_set=user_set,
            )
        )
    return entries


def merge_aliases(
    persons: dict[str, PersonRecord],
    groups: list[list[str]],
) -> dict[str, str]:
    """Build a mapping from person uuid_hex to canonical uuid_hex.

    Matches each alias term against person name, email, and the local part
    of any email-shaped name or email (the part before '@'). This lets
    SAME_PERSON_GROUPS use first names only while still matching person
    records whose name field is an email address.
    """
    # Build lookup -> list of UUIDs (handles duplicate names)
    key_to_uuids: dict[str, list[str]] = {}

    def _add(key: str, uid: str) -> None:
        key_to_uuids.setdefault(key, []).append(uid)

    for uid, p in persons.items():
        name_lc = p.name.lower()
        _add(name_lc, uid)
        # If the name looks like an email, also index by local part
        if "@" in name_lc:
            _add(name_lc.split("@")[0], uid)
        if p.email:
            email_lc = p.email.lower()
            _add(email_lc, uid)
            _add(email_lc.split("@")[0], uid)

    remap: dict[str, str] = {}
    for group in groups:
        canonical: str | None = None
        uuids: list[str] = []
        for term in group:
            matched = key_to_uuids.get(term.lower(), [])
            for uid in matched:
                if uid not in uuids:
                    uuids.append(uid)
                if canonical is None:
                    canonical = uid
        if canonical:
            for uid in uuids:
                remap[uid] = canonical
    return remap


# ---------------------------------------------------------------------------
# Scoring functions
# ---------------------------------------------------------------------------


def cosine_distance(a: np.ndarray, b: np.ndarray) -> float:
    """Cosine distance between two L2-normalized vectors: clamp(1 - dot, 0, 2)."""
    dot = float(np.dot(a, b))
    return max(0.0, min(2.0, 1.0 - dot))


def l2_normalize(v: np.ndarray) -> np.ndarray | None:
    """L2-normalize to unit length. Returns None if zero-norm or non-finite."""
    if not np.all(np.isfinite(v)):
        return None
    norm = np.linalg.norm(v)
    if norm == 0:
        return None
    return v / norm


def l2_normalize_to_sqrt_dim(v: np.ndarray) -> np.ndarray | None:
    """L2-normalize then scale to sqrt(dim)."""
    normed = l2_normalize(v)
    if normed is None:
        return None
    return normed * math.sqrt(len(v))


def plda_llr_single(
    enroll: np.ndarray,
    test: np.ndarray,
    phi: np.ndarray,
    n_enroll: float = 1.0,
) -> float:
    """
    PLDA log-likelihood ratio for one enrollment-test pair.

    Based on wespeaker TwoCovPLDA.log_likelihood_ratio.
    Source: wenet-e2e/wespeaker, wespeaker/utils/plda/two_cov_plda.py

    Both vectors must be in the diagonalized PLDA space (within-class cov = I,
    between-class cov = diag(phi)).

    Parameters:
        enroll: enrollment centroid (mean of n_enroll embeddings), D-dim
        test:   test vector, D-dim
        phi:    between-class covariance eigenvalues, D-dim
        n_enroll: number of enrollment utterances (default 1)

    Returns:
        LLR score (higher = more likely same speaker)
    """
    # Same-speaker hypothesis
    posterior_mean = n_enroll * phi / (n_enroll * phi + 1.0) * enroll
    posterior_var = 1.0 + phi / (n_enroll * phi + 1.0)
    log_det_same = np.sum(np.log(posterior_var))
    diff_same = test - posterior_mean
    mahal_same = np.sum(diff_same ** 2 / posterior_var)

    # Different-speaker hypothesis
    marginal_var = phi + 1.0
    log_det_diff = np.sum(np.log(marginal_var))
    mahal_diff = np.sum(test ** 2 / marginal_var)

    # LLR (the dim * log(2*pi) terms cancel)
    llr = -0.5 * (log_det_same + mahal_same) + 0.5 * (log_det_diff + mahal_diff)
    return float(llr)


def plda_llr_batch(
    Fe: np.ndarray,
    Ft: np.ndarray,
    phi: np.ndarray,
) -> np.ndarray:
    """
    Batch PLDA LLR for n=1 (single enrollment). Returns N x M score matrix.

    Based on VBx PLDA_scoring_in_LDA_space.
    Source: BUTSpeechFIT/VBx, VBx/diarization_lib.py
    """
    iTC = 1.0 / (1.0 + phi)
    iWC2AC = 1.0 / (1.0 + 2.0 * phi)
    ldTC = np.sum(np.log(1.0 + phi))
    ldWC2AC = np.sum(np.log(1.0 + 2.0 * phi))
    Gamma = -0.25 * (iWC2AC + 1.0 - 2.0 * iTC)
    Lambda = -0.5 * (iWC2AC - 1.0)
    k = -0.5 * (ldWC2AC - 2.0 * ldTC)
    return (Fe * Lambda) @ Ft.T + (Fe ** 2) @ Gamma[:, np.newaxis] + (Ft ** 2 @ Gamma) + k


def phi_weighted_cosine_distance(
    a: np.ndarray, b: np.ndarray, phi: np.ndarray
) -> float:
    """Phi-weighted cosine distance: 1 - (sum(phi*a*b) / (||a||_phi * ||b||_phi))."""
    weighted_dot = np.sum(phi * a * b)
    norm_a = math.sqrt(float(np.sum(phi * a * a)))
    norm_b = math.sqrt(float(np.sum(phi * b * b)))
    if norm_a == 0 or norm_b == 0:
        return 2.0
    sim = weighted_dot / (norm_a * norm_b)
    return max(0.0, min(2.0, 1.0 - float(sim)))


# ---------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------


def run_self_test() -> None:
    """Verify scoring formulas against reference implementations."""
    print("Running self-tests...")
    phi5 = np.array([25.88, 10.65, 7.10, 5.71, 5.27], dtype=np.float64)
    np.random.seed(42)
    e = np.random.randn(5) * 0.5
    t = np.random.randn(5) * 0.5

    # Test 1: wespeaker single (n=1) matches VBx batch
    ws_score = plda_llr_single(e, t, phi5, n_enroll=1.0)
    batch_mat = plda_llr_batch(e.reshape(1, -1), t.reshape(1, -1), phi5)
    vbx_score = float(batch_mat[0, 0])
    diff = abs(ws_score - vbx_score)
    assert diff < 1e-10, f"wespeaker vs VBx mismatch: {ws_score} vs {vbx_score} (diff {diff})"
    print(f"  [PASS] wespeaker single == VBx batch (diff={diff:.2e})")

    # Test 2: same-speaker score is positive
    same_score = plda_llr_single(e, e, phi5, n_enroll=1.0)
    assert same_score > 0, f"same-speaker score should be positive: {same_score}"
    print(f"  [PASS] same-speaker score positive: {same_score:.4f}")

    # Test 3: different-speaker score is negative (distant vectors)
    far = np.array([5.0, -4.0, 3.0, -2.0, 6.0])
    diff_score = plda_llr_single(e, far, phi5, n_enroll=1.0)
    assert diff_score < 0, f"different-speaker score should be negative: {diff_score}"
    print(f"  [PASS] different-speaker score negative: {diff_score:.4f}")

    # Test 4: hand-computed value for a trivial case
    # With phi = [1.0], e = [1.0], t = [1.0], n=1:
    #   same_mean = 1*1/(1*1+1) * 1 = 0.5
    #   same_var = 1 + 1/(1*1+1) = 1.5
    #   diff_var = 1+1 = 2
    #   LLR = -0.5*(log(1.5) + (1-0.5)^2/1.5) + 0.5*(log(2) + 1^2/2)
    #       = -0.5*(0.4055 + 0.1667) + 0.5*(0.6931 + 0.5)
    #       = -0.2861 + 0.5966 = 0.3105
    phi1 = np.array([1.0])
    e1 = np.array([1.0])
    t1 = np.array([1.0])
    hand = plda_llr_single(e1, t1, phi1, n_enroll=1.0)
    expected = -0.5 * (math.log(1.5) + 0.25 / 1.5) + 0.5 * (math.log(2.0) + 0.5)
    assert abs(hand - expected) < 1e-10, f"hand-computed mismatch: {hand} vs {expected}"
    print(f"  [PASS] hand-computed value: {hand:.6f} == {expected:.6f}")

    # Test 5: n > 1 changes the score
    n1_score = plda_llr_single(e, t, phi5, n_enroll=1.0)
    n10_score = plda_llr_single(e, t, phi5, n_enroll=10.0)
    assert n1_score != n10_score, "n=1 and n=10 should differ"
    print(f"  [PASS] n=1 ({n1_score:.4f}) != n=10 ({n10_score:.4f})")

    # Test 6: batch matrix is symmetric for same input
    X = np.random.randn(3, 5)
    mat = plda_llr_batch(X, X, phi5)
    assert np.allclose(mat, mat.T, atol=1e-10), "batch matrix should be symmetric"
    print("  [PASS] batch matrix symmetric")

    print("All self-tests passed.\n")


# ---------------------------------------------------------------------------
# Evaluation
# ---------------------------------------------------------------------------


@dataclass
class ScoringMethod:
    name: str
    # True if higher score = more similar (LLR). False if lower = more similar (distance).
    higher_is_better: bool


@dataclass
class TrialResult:
    method: str
    query_person: str  # canonical person name
    query_meeting_pk: int  # meeting PK (privacy-safe)
    query_speaker_id: int
    query_user_set: bool
    best_match_person: str
    best_match_score: float
    correct: bool
    # All scores for genuine and impostor for DET
    genuine_scores: list[float] = field(default_factory=list)
    impostor_scores: list[float] = field(default_factory=list)


def compute_eer(
    genuine: list[float], impostor: list[float], higher_is_better: bool
) -> tuple[float, float]:
    """
    Compute EER and the threshold at which it occurs.
    Returns (eer, threshold).
    """
    if not genuine or not impostor:
        return 1.0, 0.0

    all_scores = sorted(set(genuine + impostor))
    best_eer = 1.0
    best_thresh = 0.0

    for thresh in all_scores:
        if higher_is_better:
            fnr = sum(1 for g in genuine if g < thresh) / len(genuine)
            fpr = sum(1 for i in impostor if i >= thresh) / len(impostor)
        else:
            fnr = sum(1 for g in genuine if g > thresh) / len(genuine)
            fpr = sum(1 for i in impostor if i <= thresh) / len(impostor)

        eer = abs(fnr - fpr)
        if eer < best_eer:
            best_eer = eer
            best_thresh = thresh

    # The actual EER is approximately (fnr+fpr)/2 at the crossing
    if higher_is_better:
        fnr = sum(1 for g in genuine if g < best_thresh) / len(genuine)
        fpr = sum(1 for i in impostor if i >= best_thresh) / len(impostor)
    else:
        fnr = sum(1 for g in genuine if g > best_thresh) / len(genuine)
        fpr = sum(1 for i in impostor if i <= best_thresh) / len(impostor)

    return (fnr + fpr) / 2.0, best_thresh


def _check_finite(v: np.ndarray) -> np.ndarray | None:
    """Return v if all finite and non-zero norm, else None."""
    if not np.all(np.isfinite(v)):
        return None
    if np.linalg.norm(v) == 0:
        return None
    return v


def run_evaluation(
    entries: list[VoiceprintEntry],
    persons: dict[str, PersonRecord],
    alias_remap: dict[str, str],
    kind_filter: str,
) -> dict[str, list[TrialResult]]:
    """
    Leave-one-meeting-out evaluation for all scoring methods on one kind.

    Trials-without-history are skipped (matching VoiceprintEvaluator).

    Returns {method_name: [TrialResult]}.
    """
    # Filter to this kind
    kind_entries = [e for e in entries if e.kind == kind_filter]

    # Build methods list
    if kind_filter == "raw":
        methods = [ScoringMethod("raw_cosine", higher_is_better=False)]
    else:
        methods = [
            ScoringMethod("plda_cosine", higher_is_better=False),
            ScoringMethod("plda_llr_stored_n1", higher_is_better=True),
            ScoringMethod("plda_llr_stored_nest", higher_is_better=True),
            ScoringMethod("plda_llr_renorm_n1", higher_is_better=True),
            ScoringMethod("plda_llr_renorm_nest", higher_is_better=True),
            ScoringMethod("plda_llr_centered_n1", higher_is_better=True),
            ScoringMethod("phi_weighted_cosine", higher_is_better=False),
        ]

    # Group by meeting
    meetings: dict[int, list[VoiceprintEntry]] = {}
    for e in kind_entries:
        meetings.setdefault(e.meeting_pk, []).append(e)

    # Compute corpus mean for the centered LLR variant
    all_vecs = np.array([e.vector for e in kind_entries])
    corpus_mean = np.mean(all_vecs, axis=0)

    # Prepare vector caches
    # unit-norm cache: for cosine methods
    unit_cache: dict[int, dict[int, np.ndarray | None]] = {}
    # sqrt(dim) cache: for LLR renorm variants
    sqrt_cache: dict[int, dict[int, np.ndarray | None]] = {}
    # raw cache: for LLR as-stored variants (just finite-checked)
    raw_cache: dict[int, dict[int, np.ndarray | None]] = {}
    # centered cache: for mean-centered LLR variant
    centered_cache: dict[int, dict[int, np.ndarray | None]] = {}

    for e in kind_entries:
        if e.meeting_pk not in unit_cache:
            unit_cache[e.meeting_pk] = {}
            sqrt_cache[e.meeting_pk] = {}
            raw_cache[e.meeting_pk] = {}
            centered_cache[e.meeting_pk] = {}
        unit_cache[e.meeting_pk][e.speaker_id] = l2_normalize(e.vector)
        sqrt_cache[e.meeting_pk][e.speaker_id] = l2_normalize_to_sqrt_dim(e.vector)
        raw_cache[e.meeting_pk][e.speaker_id] = _check_finite(e.vector)
        centered_cache[e.meeting_pk][e.speaker_id] = _check_finite(e.vector - corpus_mean)

    # Build per-person tagged entry set (for trials-without-history check)
    def person_has_history(canonical_uuid: str, exclude_meeting_pk: int) -> bool:
        """True if this person has at least one tagged entry outside the given meeting."""
        for e in kind_entries:
            if e.meeting_pk == exclude_meeting_pk:
                continue
            if e.person_uuid_hex is None:
                continue
            ec = alias_remap.get(e.person_uuid_hex, e.person_uuid_hex)
            if ec == canonical_uuid:
                return True
        return False

    results: dict[str, list[TrialResult]] = {m.name: [] for m in methods}
    skipped_no_history = 0

    for query_meeting_pk, query_entries in meetings.items():
        for query_entry in query_entries:
            # Must have a tag
            if query_entry.person_uuid_hex is None:
                continue

            # Resolve canonical person
            canonical = alias_remap.get(query_entry.person_uuid_hex, query_entry.person_uuid_hex)
            truth_person = persons.get(canonical)
            if truth_person is None:
                continue

            # Skip trials without history (matches VoiceprintEvaluator)
            if not person_has_history(canonical, query_meeting_pk):
                skipped_no_history += 1
                continue

            truth_name = truth_person.name

            # Build the "rest" corpus: all entries NOT in this meeting
            rest_entries = [
                e for e in kind_entries if e.meeting_pk != query_meeting_pk
            ]
            if not rest_entries:
                continue

            # For each method, find the best match and compute DET distances
            for method in methods:
                scores_by_person: dict[str, float] = {}  # canonical_uuid -> best score

                for rest_entry in rest_entries:
                    if rest_entry.person_uuid_hex is None:
                        continue
                    rest_canonical = alias_remap.get(
                        rest_entry.person_uuid_hex, rest_entry.person_uuid_hex
                    )

                    score = _compute_score(
                        method.name,
                        query_entry,
                        rest_entry,
                        unit_cache,
                        sqrt_cache,
                        raw_cache,
                        centered_cache,
                    )
                    if score is None:
                        continue

                    if method.higher_is_better:
                        if rest_canonical not in scores_by_person or score > scores_by_person[rest_canonical]:
                            scores_by_person[rest_canonical] = score
                    else:
                        if rest_canonical not in scores_by_person or score < scores_by_person[rest_canonical]:
                            scores_by_person[rest_canonical] = score

                if not scores_by_person:
                    continue

                # Find the best match
                if method.higher_is_better:
                    best_person = max(scores_by_person, key=scores_by_person.get)  # type: ignore[arg-type]
                else:
                    best_person = min(scores_by_person, key=scores_by_person.get)  # type: ignore[arg-type]

                best_score = scores_by_person[best_person]
                correct = best_person == canonical

                # Genuine and impostor scores for DET
                genuine: list[float] = []
                impostor: list[float] = []
                for p_uuid, sc in scores_by_person.items():
                    if p_uuid == canonical:
                        genuine.append(sc)
                    else:
                        impostor.append(sc)

                best_match_name = persons.get(best_person, PersonRecord(0, best_person, None, best_person)).name

                results[method.name].append(
                    TrialResult(
                        method=method.name,
                        query_person=truth_name,
                        query_meeting_pk=query_entry.meeting_pk,
                        query_speaker_id=query_entry.speaker_id,
                        query_user_set=query_entry.user_set,
                        best_match_person=best_match_name,
                        best_match_score=best_score,
                        correct=correct,
                        genuine_scores=genuine,
                        impostor_scores=impostor,
                    )
                )

    if skipped_no_history > 0:
        print(f"  Skipped {skipped_no_history} trials (no history for truth person)")

    return results


def _compute_score(
    method_name: str,
    query: VoiceprintEntry,
    target: VoiceprintEntry,
    unit_cache: dict[int, dict[int, np.ndarray | None]],
    sqrt_cache: dict[int, dict[int, np.ndarray | None]],
    raw_cache: dict[int, dict[int, np.ndarray | None]],
    centered_cache: dict[int, dict[int, np.ndarray | None]],
) -> float | None:
    """Compute a single score between query and target for the given method."""
    if method_name == "raw_cosine":
        q = unit_cache[query.meeting_pk].get(query.speaker_id)
        t = unit_cache[target.meeting_pk].get(target.speaker_id)
        if q is None or t is None:
            return None
        return cosine_distance(q, t)

    elif method_name == "plda_cosine":
        q = unit_cache[query.meeting_pk].get(query.speaker_id)
        t = unit_cache[target.meeting_pk].get(target.speaker_id)
        if q is None or t is None:
            return None
        return cosine_distance(q, t)

    elif method_name == "plda_llr_stored_n1":
        q = raw_cache[query.meeting_pk].get(query.speaker_id)
        t = raw_cache[target.meeting_pk].get(target.speaker_id)
        if q is None or t is None:
            return None
        return plda_llr_single(t, q, PHI, n_enroll=1.0)

    elif method_name == "plda_llr_stored_nest":
        q = raw_cache[query.meeting_pk].get(query.speaker_id)
        t = raw_cache[target.meeting_pk].get(target.speaker_id)
        if q is None or t is None:
            return None
        n_enroll = max(1.0, target.speaking_duration)
        return plda_llr_single(t, q, PHI, n_enroll=n_enroll)

    elif method_name == "plda_llr_renorm_n1":
        q = sqrt_cache[query.meeting_pk].get(query.speaker_id)
        t = sqrt_cache[target.meeting_pk].get(target.speaker_id)
        if q is None or t is None:
            return None
        return plda_llr_single(t, q, PHI, n_enroll=1.0)

    elif method_name == "plda_llr_renorm_nest":
        q = sqrt_cache[query.meeting_pk].get(query.speaker_id)
        t = sqrt_cache[target.meeting_pk].get(target.speaker_id)
        if q is None or t is None:
            return None
        n_enroll = max(1.0, target.speaking_duration)
        return plda_llr_single(t, q, PHI, n_enroll=n_enroll)

    elif method_name == "plda_llr_centered_n1":
        q = centered_cache[query.meeting_pk].get(query.speaker_id)
        t = centered_cache[target.meeting_pk].get(target.speaker_id)
        if q is None or t is None:
            return None
        return plda_llr_single(t, q, PHI, n_enroll=1.0)

    elif method_name == "phi_weighted_cosine":
        q = unit_cache[query.meeting_pk].get(query.speaker_id)
        t = unit_cache[target.meeting_pk].get(target.speaker_id)
        if q is None or t is None:
            return None
        return phi_weighted_cosine_distance(q, t, PHI)

    return None


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------


def print_summary(
    all_results: dict[str, list[TrialResult]],
    tag_filter: str,
) -> str:
    """Print a summary table and return it as a string."""
    lines: list[str] = []
    lines.append(f"\n### {tag_filter} trials\n")

    header = f"{'Method':<28} {'Trials':>6} {'Top-1':>6} {'Top-1%':>7} {'EER':>6} {'EER_thresh':>10} {'Gen_min':>8} {'Gen_med':>8} {'Imp_max':>8} {'Imp_med':>8} {'Margin':>7}"
    lines.append(header)
    lines.append("-" * len(header))

    for method_name, trials in sorted(all_results.items()):
        if tag_filter == "confirmed":
            filtered = [t for t in trials if t.query_user_set]
        elif tag_filter == "inferred":
            filtered = [t for t in trials if not t.query_user_set]
        else:
            filtered = trials

        if not filtered:
            continue

        n_trials = len(filtered)
        n_correct = sum(1 for t in filtered if t.correct)
        pct = 100.0 * n_correct / n_trials if n_trials > 0 else 0

        all_genuine = [s for t in filtered for s in t.genuine_scores]
        all_impostor = [s for t in filtered for s in t.impostor_scores]

        higher_is_better = "llr" in method_name
        eer, eer_thresh = compute_eer(all_genuine, all_impostor, higher_is_better)

        if all_genuine:
            gen_min = min(all_genuine)
            gen_med = float(np.median(all_genuine))
        else:
            gen_min = gen_med = float("nan")

        if all_impostor:
            imp_max = max(all_impostor)
            imp_med = float(np.median(all_impostor))
        else:
            imp_max = imp_med = float("nan")

        # Margin: for distances, min_impostor - max_genuine (positive = separable).
        # For LLR, min_genuine - max_impostor (positive = separable).
        if all_genuine and all_impostor:
            if higher_is_better:
                margin = gen_min - imp_max
            else:
                margin = min(all_impostor) - max(all_genuine)
        else:
            margin = float("nan")

        lines.append(
            f"{method_name:<28} {n_trials:>6} {n_correct:>6} {pct:>6.1f}% {eer:>6.3f} {eer_thresh:>10.4f} {gen_min:>8.4f} {gen_med:>8.4f} {imp_max:>8.4f} {imp_med:>8.4f} {margin:>+7.3f}"
        )

    text = "\n".join(lines)
    print(text)
    return text


def print_mismatches(
    all_results: dict[str, list[TrialResult]],
    persons: dict[str, PersonRecord],
) -> str:
    """Print every mismatch for hand-review (using meeting PK, not title)."""
    lines: list[str] = []
    lines.append("\n### Mismatches (all methods, confirmed trials only)\n")

    for method_name, trials in sorted(all_results.items()):
        mismatches = [t for t in trials if not t.correct and t.query_user_set]
        if not mismatches:
            continue
        lines.append(f"\n**{method_name}** ({len(mismatches)} mismatches):\n")
        for t in mismatches:
            lines.append(
                f"  - meeting_pk={t.query_meeting_pk} | speaker {t.query_speaker_id} "
                f"| truth: {t.query_person} | predicted: {t.best_match_person} "
                f"| score: {t.best_match_score:.4f}"
            )

    text = "\n".join(lines)
    print(text)
    return text


# ---------------------------------------------------------------------------
# Pairwise verification analysis
# ---------------------------------------------------------------------------


@dataclass
class PairwiseResult:
    method: str
    n_same: int
    n_diff: int
    same_scores: list[float]
    diff_scores: list[float]
    eer: float
    eer_thresh: float
    auc: float
    d_prime: float  # d' separation measure


def compute_auc(
    same: list[float], diff: list[float], higher_is_better: bool
) -> float:
    """ROC AUC via the Mann-Whitney U statistic."""
    if not same or not diff:
        return 0.0
    n_concordant = 0
    n_tied = 0
    for s in same:
        for d in diff:
            if higher_is_better:
                if s > d:
                    n_concordant += 1
                elif s == d:
                    n_tied += 1
            else:
                if s < d:
                    n_concordant += 1
                elif s == d:
                    n_tied += 1
    total = len(same) * len(diff)
    return (n_concordant + 0.5 * n_tied) / total


def compute_d_prime(
    same: list[float], diff: list[float], higher_is_better: bool
) -> float:
    """d' (d-prime) separation: (mu_target - mu_nontarget) / sqrt(0.5*(var_t + var_nt)).

    Sign convention: positive means same-speaker scores are in the 'correct'
    direction (higher for LLR, lower for distances).
    """
    if len(same) < 2 or len(diff) < 2:
        return 0.0
    mu_s = float(np.mean(same))
    mu_d = float(np.mean(diff))
    var_s = float(np.var(same, ddof=1))
    var_d = float(np.var(diff, ddof=1))
    pooled_std = math.sqrt(0.5 * (var_s + var_d))
    if pooled_std == 0:
        return 0.0
    if higher_is_better:
        return (mu_s - mu_d) / pooled_std
    else:
        return (mu_d - mu_s) / pooled_std


def run_pairwise_verification(
    entries: list[VoiceprintEntry],
    persons: dict[str, PersonRecord],
    alias_remap: dict[str, str],
    kind_filter: str,
) -> list[PairwiseResult]:
    """
    Pairwise verification over all confirmed voiceprint pairs from different
    meetings. Computes same-person vs different-person scores for each method.
    """
    kind_entries = [
        e for e in entries
        if e.kind == kind_filter and e.person_uuid_hex is not None and e.user_set
    ]

    # Compute corpus mean (over ALL voiceprints of this kind, not just confirmed)
    all_vecs = np.array([e.vector for e in entries if e.kind == kind_filter])
    corpus_mean = np.mean(all_vecs, axis=0)

    # Build caches for confirmed entries
    unit_vecs: dict[tuple[int, int], np.ndarray | None] = {}
    sqrt_vecs: dict[tuple[int, int], np.ndarray | None] = {}
    raw_vecs: dict[tuple[int, int], np.ndarray | None] = {}
    centered_vecs: dict[tuple[int, int], np.ndarray | None] = {}

    for e in kind_entries:
        key = (e.meeting_pk, e.speaker_id)
        unit_vecs[key] = l2_normalize(e.vector)
        sqrt_vecs[key] = l2_normalize_to_sqrt_dim(e.vector)
        raw_vecs[key] = _check_finite(e.vector)
        centered_vecs[key] = _check_finite(e.vector - corpus_mean)

    # Define methods
    if kind_filter == "raw":
        method_defs: list[tuple[str, bool]] = [("raw_cosine", False)]
    else:
        method_defs = [
            ("plda_cosine", False),
            ("plda_llr_stored_n1", True),
            ("plda_llr_renorm_n1", True),
            ("plda_llr_centered_n1", True),
            ("phi_weighted_cosine", False),
        ]

    results: list[PairwiseResult] = []
    for method_name, higher_is_better in method_defs:
        same_scores: list[float] = []
        diff_scores: list[float] = []

        for i, a in enumerate(kind_entries):
            for b in kind_entries[i + 1:]:
                if a.meeting_pk == b.meeting_pk:
                    continue  # same meeting -- skip

                ka = (a.meeting_pk, a.speaker_id)
                kb = (b.meeting_pk, b.speaker_id)

                # Compute score
                if method_name in ("raw_cosine", "plda_cosine"):
                    va, vb = unit_vecs[ka], unit_vecs[kb]
                    if va is None or vb is None:
                        continue
                    score = cosine_distance(va, vb)
                elif method_name == "plda_llr_stored_n1":
                    va, vb = raw_vecs[ka], raw_vecs[kb]
                    if va is None or vb is None:
                        continue
                    score = plda_llr_single(vb, va, PHI, n_enroll=1.0)
                elif method_name == "plda_llr_renorm_n1":
                    va, vb = sqrt_vecs[ka], sqrt_vecs[kb]
                    if va is None or vb is None:
                        continue
                    score = plda_llr_single(vb, va, PHI, n_enroll=1.0)
                elif method_name == "plda_llr_centered_n1":
                    va, vb = centered_vecs[ka], centered_vecs[kb]
                    if va is None or vb is None:
                        continue
                    score = plda_llr_single(vb, va, PHI, n_enroll=1.0)
                elif method_name == "phi_weighted_cosine":
                    va, vb = unit_vecs[ka], unit_vecs[kb]
                    if va is None or vb is None:
                        continue
                    score = phi_weighted_cosine_distance(va, vb, PHI)
                else:
                    continue

                # Classify pair
                ca = alias_remap.get(a.person_uuid_hex, a.person_uuid_hex)  # type: ignore[arg-type]
                cb = alias_remap.get(b.person_uuid_hex, b.person_uuid_hex)  # type: ignore[arg-type]
                if ca == cb:
                    same_scores.append(score)
                else:
                    diff_scores.append(score)

        eer, eer_thresh = compute_eer(same_scores, diff_scores, higher_is_better)
        auc = compute_auc(same_scores, diff_scores, higher_is_better)
        dprime = compute_d_prime(same_scores, diff_scores, higher_is_better)

        results.append(PairwiseResult(
            method=method_name,
            n_same=len(same_scores),
            n_diff=len(diff_scores),
            same_scores=same_scores,
            diff_scores=diff_scores,
            eer=eer,
            eer_thresh=eer_thresh,
            auc=auc,
            d_prime=dprime,
        ))

    return results


def print_pairwise_results(results: list[PairwiseResult]) -> None:
    """Print pairwise verification results."""
    print("\n### Pairwise verification (confirmed voiceprints, cross-meeting)\n")

    dp_label = "d'"
    header = f"{'Method':<28} {'Same':>5} {'Diff':>5} {'EER':>7} {'AUC':>6} {dp_label:>6}  Same p50/p90/max    Diff min/p10"
    print(header)
    print("-" * len(header))

    for r in results:
        higher = "llr" in r.method

        if r.same_scores:
            same_arr = np.array(r.same_scores)
            if higher:
                s_p50 = float(np.percentile(same_arr, 50))
                s_p90 = float(np.percentile(same_arr, 10))  # worst 10% for LLR = low scores
                s_ext = float(np.min(same_arr))  # min for LLR
            else:
                s_p50 = float(np.percentile(same_arr, 50))
                s_p90 = float(np.percentile(same_arr, 90))
                s_ext = float(np.max(same_arr))
        else:
            s_p50 = s_p90 = s_ext = float("nan")

        if r.diff_scores:
            diff_arr = np.array(r.diff_scores)
            if higher:
                d_ext = float(np.max(diff_arr))  # max for LLR (worst impostor)
                d_p10 = float(np.percentile(diff_arr, 90))  # worst 10% for LLR = high scores
            else:
                d_ext = float(np.min(diff_arr))
                d_p10 = float(np.percentile(diff_arr, 10))
        else:
            d_ext = d_p10 = float("nan")

        print(
            f"{r.method:<28} {r.n_same:>5} {r.n_diff:>5} {r.eer:>6.3f}  {r.auc:>5.3f}  {r.d_prime:>5.2f}"
            f"  {s_p50:>6.2f}/{s_p90:>6.2f}/{s_ext:>6.2f}"
            f"  {d_ext:>6.2f}/{d_p10:>6.2f}"
        )


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main() -> None:
    parser = argparse.ArgumentParser(description="PLDA LLR benchmark")
    parser.add_argument(
        "--db",
        default=os.path.join(os.environ.get("TMPDIR", "/tmp"), "biscotti_benchmark.db"),
        help="Path to the SQLite snapshot",
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="Run formula verification tests and exit",
    )
    args = parser.parse_args()

    if args.self_test:
        run_self_test()
        return

    conn = sqlite3.connect(args.db)
    print(f"Database: {args.db}")

    # Load data
    persons = load_persons(conn)
    entries = load_voiceprints(conn)
    alias_remap = merge_aliases(persons, SAME_PERSON_GROUPS)

    print(f"Persons: {len(persons)}")
    print(f"Voiceprints loaded: {len(entries)}")
    print(f"  raw: {sum(1 for e in entries if e.kind == 'raw')}")
    print(f"  plda: {sum(1 for e in entries if e.kind == 'plda')}")

    tagged = [e for e in entries if e.person_uuid_hex is not None]
    confirmed = [e for e in tagged if e.user_set]
    inferred = [e for e in tagged if not e.user_set]
    print(f"Tagged: {len(tagged)} (confirmed: {len(confirmed)}, inferred: {len(inferred)})")
    print(f"Alias groups: {len(SAME_PERSON_GROUPS)}")

    # Corpus mean diagnostic
    plda_vecs = np.array([e.vector for e in entries if e.kind == "plda"])
    mean_norm = np.linalg.norm(np.mean(plda_vecs, axis=0))
    indiv_norms = np.linalg.norm(plda_vecs, axis=1)
    print(f"\nPLDA corpus mean L2 norm: {mean_norm:.2f}")
    print(f"PLDA individual norms: min={indiv_norms.min():.2f} median={np.median(indiv_norms):.2f} max={indiv_norms.max():.2f} (sqrt(128)={math.sqrt(128):.2f})")

    # Run evaluation for both kinds
    print("\n" + "=" * 80)
    print("EVALUATING RAW VOICEPRINTS")
    print("=" * 80)
    raw_results = run_evaluation(entries, persons, alias_remap, "raw")

    print("\n" + "=" * 80)
    print("EVALUATING PLDA VOICEPRINTS")
    print("=" * 80)
    plda_results = run_evaluation(entries, persons, alias_remap, "plda")

    # Combine all results
    all_results = {**raw_results, **plda_results}

    # Print summaries
    for tag_filter in ["all", "confirmed", "inferred"]:
        print_summary(all_results, tag_filter)

    # Print mismatches for hand-review
    print_mismatches(all_results, persons)

    # Pairwise verification analysis
    print("\n" + "=" * 80)
    print("PAIRWISE VERIFICATION (confirmed voiceprints, cross-meeting)")
    print("=" * 80)
    raw_pw = run_pairwise_verification(entries, persons, alias_remap, "raw")
    plda_pw = run_pairwise_verification(entries, persons, alias_remap, "plda")
    print_pairwise_results(raw_pw + plda_pw)

    conn.close()


if __name__ == "__main__":
    main()
