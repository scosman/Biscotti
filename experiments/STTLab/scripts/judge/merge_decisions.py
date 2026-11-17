#!/usr/bin/env python3
"""Map judged batches onto the current reports and write decision files.

Decisions are matched to report entries by content, not by ID: same Apple,
Whisper and reference text, and a start time within 3 s. So decisions survive
a re-run of `analyze prep` (which renumbers IDs and changes the fingerprint),
and only regions whose text changed need new judging.

Usage:
    merge_decisions.py --analysis "$WS/analysis" --work "$WS/judge_work" status
    merge_decisions.py ... plan    # writes <mid>_rN.input.json for unmatched regions
    merge_decisions.py ... write   # writes <analysis>/<mid>/disagreement_decision.json
                                   # for every meeting with no unmatched region

Batch files: <work>/<mid>_<tag>.input.json + <work>/<mid>_<tag>.decisions.json
(a JSON array of {id, decision, severity, note?}).
"""
import argparse
import collections
import glob
import json
import os

p = argparse.ArgumentParser()
p.add_argument("--analysis", required=True)
p.add_argument("--work", required=True)
p.add_argument("mode", choices=["status", "plan", "write"])
args = p.parse_args()

MAX_SHIFT_SECONDS = 3.0


def key(e):
    return (e["apple"], e["whisper"], e.get("reference") or "")


for rp in sorted(glob.glob(f"{args.analysis}/*/disagreement_report.json")):
    rep = json.load(open(rp))
    mid = rep["meeting_id"]

    # Pool of judged entries from all batches of this meeting.
    pool = collections.defaultdict(list)
    pending = []
    for inp in sorted(glob.glob(f"{args.work}/{mid}_*.input.json")):
        dec = inp.replace(".input.json", ".decisions.json")
        if not os.path.exists(dec):
            pending.append(os.path.basename(inp))
            continue
        by_id = {d["id"]: d for d in json.load(open(dec))}
        for e in json.load(open(inp))["disagreements"]:
            if e["id"] in by_id:
                pool[key(e)].append((e["start_seconds"], by_id[e["id"]]))

    decisions, unmatched = [], []
    for e in rep["disagreements"]:
        cands = pool.get(key(e), [])
        best = min(range(len(cands)),
                   key=lambda i: abs(cands[i][0] - e["start_seconds"]), default=None)
        if best is not None and abs(cands[best][0] - e["start_seconds"]) < MAX_SHIFT_SECONDS:
            _, d = cands.pop(best)
            nd = {"id": e["id"], "decision": d["decision"], "severity": d["severity"]}
            if d.get("note"):
                nd["note"] = d["note"]
            decisions.append(nd)
        else:
            unmatched.append(e)

    print(f"{mid}: total={len(rep['disagreements'])} matched={len(decisions)} "
          f"unmatched={len(unmatched)} pending_batches={pending}")

    if args.mode == "plan" and unmatched and not pending:
        n = 1
        while os.path.exists(f"{args.work}/{mid}_r{n}.input.json"):
            n += 1
        out = {"meeting_id": mid, "instructions": rep["instructions"],
               "engines": rep["engines"], "disagreements": unmatched}
        path = f"{args.work}/{mid}_r{n}.input.json"
        with open(path, "w") as f:
            json.dump(out, f, indent=1, ensure_ascii=False)
        print(f"  wrote {os.path.basename(path)} ({len(unmatched)} regions)")

    if args.mode == "write" and not unmatched:
        out = {"schema_version": 1, "meeting_id": mid,
               "report_fingerprint": rep["report_fingerprint"], "decisions": decisions}
        path = os.path.join(os.path.dirname(rp), "disagreement_decision.json")
        with open(path, "w") as f:
            json.dump(out, f, indent=1, ensure_ascii=False)
        print(f"  wrote {path}")
