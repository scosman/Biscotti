#!/usr/bin/env python3
"""Copy the analyze-final report with all transcript text removed.

Keeps every number; drops sections and fields that quote speech.

Usage:
    sanitize_report.py --report "$WS/report" --out <dir>

Writes <dir>/report_stats.md and <dir>/metrics_stats.json.
"""
import argparse
import json
import os
import re

p = argparse.ArgumentParser()
p.add_argument("--report", required=True)
p.add_argument("--out", required=True)
args = p.parse_args()
os.makedirs(args.out, exist_ok=True)

# --- Markdown: drop text sections; replace the per-meeting Flags column by a count.
DROP_SECTIONS = {"### Mistakes That Matter", "### Flags", "### Speaker Disagreement Sample (top 20)"}
lines = open(f"{args.report}/report.md").read().split("\n")
out, skipping = [], False
for line in lines:
    if line.startswith("#"):
        skipping = line.strip() in DROP_SECTIONS
        if skipping:
            out.append(line)
            out.append("")
            out.append("*Removed: this section quotes meeting speech.*")
            out.append("")
            continue
    if skipping:
        continue
    out.append(line)

md = "\n".join(out)


def flags_to_count(m):
    cells = m.group(0).split(" | ")
    last = cells[-1].rstrip(" |")
    # Only the per-meeting results table (15 columns) has a Flags column.
    if len(cells) < 15 or last == "—":
        return m.group(0)
    n = len(re.findall(r"(apple|whisper|reference) dropped \d+s", last))
    cells[-1] = f"{n} dropped-stretch flag(s) |"
    return " | ".join(cells)


md = re.sub(r"^\| m\d\d \|.*\|$", flags_to_count, md, flags=re.M)
with open(f"{args.out}/report_stats.md", "w") as f:
    f.write(md)

# --- JSON: drop any key whose value can hold speech text.
TEXT_KEYS = {"mistakesThatMatter", "tieBreakRegions", "tieBreakSample",
             "speakerDisagreementSample", "flags", "appleText", "whisperText",
             "refText", "referenceText", "words"}


def strip(o):
    if isinstance(o, dict):
        return {k: strip(v) for k, v in o.items() if k not in TEXT_KEYS}
    if isinstance(o, list):
        return [strip(v) for v in o]
    return o


metrics = strip(json.load(open(f"{args.report}/metrics.json")))
with open(f"{args.out}/metrics_stats.json", "w") as f:
    json.dump(metrics, f, indent=1, sort_keys=True)


# Report any long string that survived, so a human can check it.
def long_strings(o, path=""):
    if isinstance(o, dict):
        for k, v in o.items():
            yield from long_strings(v, f"{path}.{k}")
    elif isinstance(o, list):
        for i, v in enumerate(o):
            yield from long_strings(v, f"{path}[{i}]")
    elif isinstance(o, str) and len(o) > 60:
        yield path, o[:60]


left = list(long_strings(metrics))
print(f"wrote report_stats.md and metrics_stats.json; long strings left: {len(left)}")
for path, s in left[:20]:
    print(f"  {path}: {s}")
