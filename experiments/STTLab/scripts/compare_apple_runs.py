#!/usr/bin/env python3
"""Compare two Apple runner result folders (e.g. two macOS versions).

Run this first on a re-test: if the text is identical, the LLM judgements
from the earlier run all carry over and only timing/speed/memory can change.

Usage:
    compare_apple_runs.py <old-results> <new-results>

Prints counts only (no transcript text).
"""
import collections
import json
import sys


def secs(t):
    return t["seconds"] if isinstance(t, dict) else t


def load(root, mid):
    return json.load(open(f"{root}/meetings/{mid}/apple.json"))


old_root, new_root = sys.argv[1], sys.argv[2]
for root in (old_root, new_root):
    s = json.load(open(f"{root}/run.json"))["sessions"][-1]
    print(f"{root}: {s['machine']['chip']}, {s['machine']['osVersion']}")

mids = sorted(json.load(open(f"{old_root}/run.json"))["sessions"][-1]["meetingsAttempted"])
c = collections.Counter()
shifts = collections.Counter()
for mid in mids:
    a, b = load(old_root, mid), load(new_root, mid)
    ra, rb = a["results"], b["results"]
    c["results_old"] += len(ra)
    c["results_new"] += len(rb)
    if len(ra) != len(rb):
        c["meetings_with_different_result_count"] += 1
    for x, y in zip(ra, rb):
        c["result_pairs"] += 1
        c["text_same"] += x["text"] == y["text"]
        c["alternatives_same"] += [t["text"] for t in x["alternatives"]] == [t["text"] for t in y["alternatives"]]
        d = round(secs(y["rangeStart"]) - secs(x["rangeStart"]), 2)
        if d:
            shifts[d] += 1
        for u, v in zip(x["runs"], y["runs"]):
            c["runs"] += 1
            c["run_confidence_same"] += u.get("confidence") == v.get("confidence")
            c["run_start_moved_gt_0.1s"] += abs(secs(u["timeStart"]) - secs(v["timeStart"])) > 0.1
    c["new_run_asset_install_needed"] += bool(b.get("assets", {}).get("installNeeded"))

for k, v in c.items():
    print(f"{k}: {v}")
print("result start shifts (new - old, s), most common:", shifts.most_common(5))
print("TEXT IDENTICAL" if c["text_same"] == c["result_pairs"] == c["results_old"] == c["results_new"]
      else "TEXT DIFFERS: judge the changed regions")
