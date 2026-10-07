#!/usr/bin/env python3
"""
Reports the exact duration and a per-second size profile of a recording's
ADTS AAC tracks (mic.aac + system.aac), by parsing ADTS frame headers.
No dependencies; works inside the agent Bash sandbox (afinfo does not).

Run:
  python3 Tools/aac_track_report.py                 # latest recording
  python3 Tools/aac_track_report.py <UUID-or-dir>   # a specific recording
  python3 Tools/aac_track_report.py --list 10       # 10 latest recordings, durations only

Why it works: every ADTS frame holds exactly 1024 samples, so
frames * 1024 / sample_rate is the exact track length. Compare the two
tracks with each other and with wall time from the unified log
(first mic buffer -> stop): they should agree within ~0.2 s of AAC padding.
The bytes/sec profile is a rough activity signal: silence encodes small,
speech encodes larger; a run of zeros means nothing was written.
See specs/research/audio/hardware_debugging_workflow.md.
"""

import sys
from datetime import datetime
from pathlib import Path

RECORDINGS = Path.home() / "Library/Application Support/Biscotti/Recordings"
RATES = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050,
         16000, 12000, 11025, 8000, 7350]
SAMPLES_PER_FRAME = 1024


def parse_adts(path):
    """Returns (sample_rate, frame_sizes, error). error is None if the whole file parsed."""
    data = path.read_bytes()
    i, sizes, rate = 0, [], None
    while i + 7 <= len(data):
        if data[i] != 0xFF or (data[i + 1] & 0xF0) != 0xF0:
            return rate, sizes, f"lost ADTS sync at byte {i} of {len(data)}"
        rate = RATES[(data[i + 2] >> 2) & 0xF]
        length = ((data[i + 3] & 0x03) << 11) | (data[i + 4] << 3) | (data[i + 5] >> 5)
        if length < 7:
            return rate, sizes, f"bad frame length {length} at byte {i}"
        sizes.append(length)
        i += length
    if i != len(data):
        return rate, sizes, f"{len(data) - i} trailing bytes"
    return rate, sizes, None


def describe(path, profile=True):
    if not path.exists():
        print(f"  {path.name}: MISSING")
        return None
    size = path.stat().st_size
    mtime = datetime.fromtimestamp(path.stat().st_mtime).strftime("%Y-%m-%d %H:%M:%S")
    if size == 0:
        print(f"  {path.name}: 0 bytes (mtime {mtime}) -- nothing was ever written")
        return 0.0
    rate, sizes, err = parse_adts(path)
    duration = len(sizes) * SAMPLES_PER_FRAME / rate if rate else 0.0
    print(f"  {path.name}: {size} bytes, {rate} Hz, {len(sizes)} frames, "
          f"{duration:.2f} s (mtime {mtime})" + (f"  !! {err}" if err else ""))
    if profile and rate:
        fps = rate / SAMPLES_PER_FRAME
        per_sec = [sum(sizes[int(s * fps):int((s + 1) * fps)]) for s in range(int(duration) + 1)]
        print(f"    bytes/sec: {per_sec}")
    return duration


def report(rec_dir, profile=True):
    print(rec_dir.name)
    mic = describe(rec_dir / "mic.aac", profile)
    system = describe(rec_dir / "system.aac", profile)
    if mic is not None and system is not None:
        print(f"  mic - system = {mic - system:+.2f} s")


def main(args):
    if args and args[0] == "--list":
        count = int(args[1]) if len(args) > 1 else 10
        dirs = sorted((d for d in RECORDINGS.iterdir() if d.is_dir()),
                      key=lambda d: d.stat().st_mtime, reverse=True)[:count]
        for d in dirs:
            report(d, profile=False)
        return
    if args:
        candidate = Path(args[0])
        rec_dir = candidate if candidate.is_dir() else RECORDINGS / args[0]
    else:
        rec_dir = max((d for d in RECORDINGS.iterdir() if d.is_dir()),
                      key=lambda d: d.stat().st_mtime)
    report(rec_dir)


if __name__ == "__main__":
    main(sys.argv[1:])
