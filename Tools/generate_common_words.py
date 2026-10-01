#!/usr/bin/env python3
"""
Regenerates Packages/BiscottiKit/Sources/Vocabulary/Resources/common_words_en.txt

Run:  uv run --with wordfreq python Tools/generate_common_words.py

Keeps words where:
  - zipf_frequency(w, 'en') >= 3.0
  - w.isalpha()  (letters only, no digits/hyphens/punctuation)
  - len(w) >= 3

Output: one lowercase word per line, sorted, LF-terminated, UTF-8.
"""

import os
from pathlib import Path

from wordfreq import zipf_frequency

# wordfreq's get_frequency_dict returns {word: freq} for a given language+wordlist.
from wordfreq import get_frequency_dict

THRESHOLD = 3.0
MIN_LENGTH = 3

OUTPUT_PATH = (
    Path(__file__).resolve().parent.parent
    / "Packages"
    / "BiscottiKit"
    / "Sources"
    / "Vocabulary"
    / "Resources"
    / "common_words_en.txt"
)


def main() -> None:
    words = get_frequency_dict("en", wordlist="large")
    out = sorted(
        w
        for w in words
        if w.isalpha() and len(w) >= MIN_LENGTH and zipf_frequency(w, "en") >= THRESHOLD
    )

    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    with open(OUTPUT_PATH, "w", encoding="utf-8", newline="\n") as f:
        for word in out:
            f.write(word + "\n")

    size_bytes = os.path.getsize(OUTPUT_PATH)
    print(f"Wrote {len(out)} words ({size_bytes:,} bytes) to {OUTPUT_PATH}")

    # Verification: confirm 'parakeet' is absent (zipf < 3.0)
    parakeet_zipf = zipf_frequency("parakeet", "en")
    if "parakeet" in set(out):
        print(f"WARNING: 'parakeet' IS in the list (zipf={parakeet_zipf:.2f})")
    else:
        print(f"Verified: 'parakeet' is absent from the list (zipf={parakeet_zipf:.2f})")


if __name__ == "__main__":
    main()
