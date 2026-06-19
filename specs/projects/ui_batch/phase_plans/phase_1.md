---
status: complete
---

# Phase 1: Record button size

## Overview

Make the idle top-right toolbar "Record" button one size step taller/bigger so it reads as a visual peer to the recording-state "REC m:ss" button (which has `frame(height: 34)`). Currently the idle button has small padding (10h/4v) and no fixed height, making it look cramped.

## Steps

1. **Increase `ToolbarRecordButtonStyle` size** in `DesignSystem/JoinRecordButtonStyle.swift` (~line 45):
   - Bump font from `.system(size: 13, weight: .medium)` to `.system(size: 14, weight: .medium)` (one step up).
   - Increase vertical padding from 4pt to 8pt, giving a taller hit area.
   - Increase horizontal padding from 10pt to 14pt for proportional width.
   - Add `.frame(minHeight: 34)` to match the recording button's height, so there's no jarring toolbar jump on state change.

These changes keep the sage fill, label, icon, and pressed-dim behavior intact. The button will be visibly taller/larger (one control-size step) and near-equal height to the 34pt recording button.

## Tests

- NA: This is a visual/style-only change to a `ButtonStyle`. There are no behavioral tests to write; correctness is verified by `lint` + `build_app` green and visual inspection.
