#!/usr/bin/env python3
"""Unblind and summarize the reference-quality check.

Reads <work>/key.json, <work>/batchN.result.json (accuracy) and
<work>/styleN.result.json (style). Prints counts only (no transcript text).

Usage:
    refcheck_summarize.py --work "$WS/refcheck"
"""
import argparse
import collections
import glob
import json

p = argparse.ArgumentParser()
p.add_argument("--work", required=True)
args = p.parse_args()

key = json.load(open(f"{args.work}/key.json"))
ENGINES = ["reference", "whisper", "apple"]

first, last = collections.Counter(), collections.Counter()
ranks, errors = collections.defaultdict(list), collections.Counter()
margins, per_meeting = collections.Counter(), collections.defaultdict(collections.Counter)
n = 0
for f in sorted(glob.glob(f"{args.work}/batch*.result.json")):
    for r in json.load(open(f)):
        k = key[r["window_id"]]
        order = [k[label] for label in r["ranking"]]
        n += 1
        first[order[0]] += 1
        last[order[-1]] += 1
        for i, e in enumerate(order):
            ranks[e].append(i + 1)
        for label, c in r["errors"].items():
            errors[k[label]] += c
        margins[(order[0], r["margin"])] += 1
        per_meeting[r["window_id"].split("_")[0]][order[0]] += 1

print(f"Accuracy pass: {n} windows")
print("| Engine | Ranked 1st | Ranked last | Mean rank | Clear errors / window |")
print("|---|---|---|---|---|")
for e in ENGINES:
    if ranks[e]:
        print(f"| {e} | {first[e]} | {last[e]} | {sum(ranks[e]) / len(ranks[e]):.2f} "
              f"| {errors[e] / n:.2f} |")
print("Winner margins:", dict(margins))
print("Firsts per meeting:", {m: dict(c) for m, c in sorted(per_meeting.items())})

scores = collections.defaultdict(lambda: collections.defaultdict(list))
preferred, m = collections.Counter(), 0
for f in sorted(glob.glob(f"{args.work}/style*.result.json")):
    for r in json.load(open(f)):
        k = key[r["window_id"]]
        m += 1
        for label, sc in r["scores"].items():
            for dim, v in sc.items():
                scores[k[label]][dim].append(v)
        preferred[k[r["preferred"]]] += 1
if m:
    dims = ["punctuation", "capitalization", "segmentation", "readability"]
    print(f"\nStyle pass: {m} windows (scores 1-5)")
    print("| Engine | " + " | ".join(dims) + " | Preferred |")
    print("|---|" + "---|" * (len(dims) + 1))
    for e in ENGINES:
        vals = " | ".join(f"{sum(scores[e][d]) / len(scores[e][d]):.2f}" for d in dims)
        print(f"| {e} | {vals} | {preferred[e]} |")
