#!/usr/bin/env python3
"""Build blind three-way passage windows to check the reference's quality.

Takes four 90 s windows per meeting (at 20/40/60/80 % of the duration). For
each window, extracts Apple, Whisper and reference text, shuffles them as
X/Y/Z, and writes batches of 8 windows. A key file maps labels back to engines.

Apple and Whisper text comes from report/transcripts/<mid>/<engine>.speakers.md.
Reference text comes from the raw chunk responses (word times + chunk offset).

Usage:
    refcheck_build.py --workspace "$WS" --work "$WS/refcheck" [--report "$WS/report"]

Outputs: <work>/batchN.json (accuracy pass), <work>/styleN.json (style pass:
one window per meeting), <work>/key.json.
"""
import argparse
import glob
import json
import os
import random
import re

p = argparse.ArgumentParser()
p.add_argument("--workspace", required=True)
p.add_argument("--work", required=True)
p.add_argument("--report", help="analyze-final output dir (default: <workspace>/report)")
p.add_argument("--window-seconds", type=int, default=90)
p.add_argument("--seed", type=int, default=7)
args = p.parse_args()

W = args.workspace
T = f"{args.report or W + '/report'}/transcripts"
LINE = re.compile(r"^\[(\d+):(\d\d)\] Speaker \d+:\s*(.*)$")


def load_speakers_md(path):
    out = []
    for line in open(path):
        m = LINE.match(line.rstrip("\n"))
        if m:
            out.append((int(m[1]) * 60 + int(m[2]), m[3].strip()))
    return out


def load_reference(mid):
    meta = json.load(open(f"{W}/bundle/meetings/{mid}/meta.json"))
    sr = meta.get("sampleRate", 16000)
    out = []
    for mp in glob.glob(f"{W}/home/reference/{mid}/*.meta.json"):
        rp = mp.replace(".meta.json", ".response.json")
        if not os.path.exists(rp):
            continue
        offset = json.load(open(mp))["startSample"] / sr
        for w in json.load(open(rp)).get("words") or []:
            out.append((w["start"] + offset, w["word"].strip()))
    out.sort(key=lambda x: x[0])  # keep word order: sort by exact start time
    return out


os.makedirs(args.work, exist_ok=True)
rng = random.Random(args.seed)
windows, key = [], {}
for md in sorted(glob.glob(f"{T}/m*")):
    mid = os.path.basename(md)
    eng = {e: load_speakers_md(f"{md}/{e}.speakers.md") for e in ["apple", "whisper"]}
    eng["reference"] = load_reference(mid)
    dur = max(t for t, _ in eng["reference"])
    for k, frac in enumerate([0.2, 0.4, 0.6, 0.8]):
        t0 = int(dur * frac)
        t1 = t0 + args.window_seconds
        texts = {e: " ".join(x for t, x in v if t0 <= t < t1) for e, v in eng.items()}
        order = list(texts)
        rng.shuffle(order)
        labels = ["X", "Y", "Z"]
        wid = f"{mid}_w{k + 1}"
        key[wid] = dict(zip(labels, order))
        windows.append({"window_id": wid, "start": f"{t0 // 60}:{t0 % 60:02d}",
                        "transcripts": {lab: texts[e] for lab, e in zip(labels, order)}})

with open(f"{args.work}/key.json", "w") as f:
    json.dump(key, f, indent=1)
for i in range(0, len(windows), 8):
    with open(f"{args.work}/batch{i // 8 + 1}.json", "w") as f:
        json.dump(windows[i:i + 8], f, indent=1, ensure_ascii=False)
style = [w for w in windows if w["window_id"].endswith("_w2")]
for i in range(0, len(style), 8):
    with open(f"{args.work}/style{i // 8 + 1}.json", "w") as f:
        json.dump(style[i:i + 8], f, indent=1, ensure_ascii=False)
print(f"{len(windows)} windows in {(len(windows) + 7) // 8} accuracy batches; "
      f"{len(style)} style windows")
