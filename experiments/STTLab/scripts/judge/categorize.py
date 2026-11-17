#!/usr/bin/env python3
"""Categorize med/high LLM-judged mistakes by type (technical term, name, ...).

Usage:
    categorize.py --analysis "$WS/analysis" --work "$WS/categorize" build [--batches 6]
    # one agent per batch: prompts/categorize_mistakes.md -> catN.result.json
    categorize.py --analysis "$WS/analysis" --work "$WS/categorize" summarize

`summarize` prints counts only (no transcript text).
"""
import argparse
import collections
import glob
import json
import os

p = argparse.ArgumentParser()
p.add_argument("--analysis", required=True)
p.add_argument("--work", required=True)
p.add_argument("mode", choices=["build", "summarize"])
p.add_argument("--batches", type=int, default=6)
args = p.parse_args()


def load_mistakes():
    items = []
    for rp in sorted(glob.glob(f"{args.analysis}/*/disagreement_report.json")):
        dp = rp.replace("disagreement_report.json", "disagreement_decision.json")
        if not os.path.exists(dp):
            continue
        entries = {e["id"]: e for e in json.load(open(rp))["disagreements"]}
        for d in json.load(open(dp))["decisions"]:
            if d["decision"] in ("apple_wins", "whisper_wins") and d["severity"] in ("med", "high"):
                e = entries[d["id"]]
                items.append({"id": d["id"],
                              "loser": "whisper" if d["decision"] == "apple_wins" else "apple",
                              "severity": d["severity"], "apple": e["apple"],
                              "whisper": e["whisper"], "reference": e["reference"],
                              "judge_note": d.get("note", "")})
    return items


items = load_mistakes()
if args.mode == "build":
    os.makedirs(args.work, exist_ok=True)
    size = -(-len(items) // args.batches)
    for i in range(args.batches):
        with open(f"{args.work}/cat{i + 1}.input.json", "w") as f:
            json.dump(items[i * size:(i + 1) * size], f, indent=1, ensure_ascii=False)
    print(f"{len(items)} mistakes in {args.batches} batches")
else:
    meta = {it["id"]: it for it in items}
    cats = {}
    for f in glob.glob(f"{args.work}/cat*.result.json"):
        for r in json.load(open(f)):
            cats[r["id"]] = r["category"]
    table = collections.Counter()
    for i, c in cats.items():
        it = meta[i]
        table[(c, it["loser"], it["severity"])] += 1
    order = ["technical_term", "number_or_version", "person_name", "dropped_content",
             "hallucination", "meaning_change", "garbled_phrase", "other"]
    print(f"categorized {len(cats)} of {len(items)}")
    print("| Category | Apple med | Apple high | Apple total | Whisper med | Whisper high | Whisper total |")
    print("|---|---|---|---|---|---|---|")
    for c in order:
        a = [table[(c, "apple", s)] for s in ("med", "high")]
        w = [table[(c, "whisper", s)] for s in ("med", "high")]
        print(f"| {c} | {a[0]} | {a[1]} | {sum(a)} | {w[0]} | {w[1]} | {sum(w)} |")
