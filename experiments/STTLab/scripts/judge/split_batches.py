#!/usr/bin/env python3
"""Split each meeting's disagreement_report.json into judge batches.

Usage:
    split_batches.py --analysis "$WS/analysis" --work "$WS/judge_work" [--size 250]

Writes <work>/<mid>_bN.input.json. Each batch holds the report's instructions,
engines, and up to --size disagreements. One LLM agent judges one batch and
writes <work>/<mid>_bN.decisions.json (see prompts/region_judge.md).
"""
import argparse
import glob
import json
import math
import os

p = argparse.ArgumentParser()
p.add_argument("--analysis", required=True)
p.add_argument("--work", required=True)
p.add_argument("--size", type=int, default=250)
args = p.parse_args()

os.makedirs(args.work, exist_ok=True)
batches = []
for rp in sorted(glob.glob(f"{args.analysis}/*/disagreement_report.json")):
    rep = json.load(open(rp))
    mid, ds = rep["meeting_id"], rep["disagreements"]
    n = max(1, math.ceil(len(ds) / args.size))
    size = math.ceil(len(ds) / n) if ds else 0
    for i in range(n):
        name = f"{mid}_b{i + 1}"
        part = ds[i * size:(i + 1) * size]
        out = {"meeting_id": mid, "instructions": rep["instructions"],
               "engines": rep["engines"], "disagreements": part}
        with open(f"{args.work}/{name}.input.json", "w") as f:
            json.dump(out, f, indent=1, ensure_ascii=False)
        batches.append((name, len(part)))

print(f"{len(batches)} batches, {sum(n for _, n in batches)} disagreements")
for name, n in batches:
    print(f"  {name}: {n}")
