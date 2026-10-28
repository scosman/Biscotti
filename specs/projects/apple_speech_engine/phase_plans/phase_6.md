---
status: complete
---

# Phase 6: Re-transcribe With a Chosen Model

## Overview

Add a per-engine re-transcribe option to the meeting detail overflow menu. The user can re-transcribe a single meeting with a specific engine (Apple or Whisper) without changing their default engine selection. The job's engine determines its components and vocabulary, not the target.

## Steps

1. **`TranscriptionService` override** -- add `reTranscribe(meetingID:config:)` with an optional `TranscriptionConfig`. `runJob` and `executeJob` gain a `configOverride` parameter. When present, the override supplies config, components, and vocabulary rules instead of the manager's `jobConfig()`.

2. **`ReTranscribeMenuItem` and `ReTranscribeMenuBuilder`** -- new file `Packages/BiscottiKit/Sources/MeetingDetailUI/ReTranscribeMenuBuilder.swift`. Pure model: `ReTranscribeMenuItem` (engine, title, isEnabled) and a static builder that maps engine states + current engine into two items (Apple, Whisper) with reason text per functional spec section 12.2.

3. **`MeetingDetailViewModel` additions** -- add `currentTranscriptEngine` (derived from newest version's methodId), `reTranscribeMenuItems` (builder over `core.speechEngines` state), and `reTranscribe(with:)` (builds config from engine, calls the override, runs auto-enhancements).

4. **`MeetingDetailView` overflow menu** -- replace the single Re-transcribe `Button` with a nested `Menu` containing engine items per ui_design section 7.

5. **Tests** -- `TranscriptionServiceOverrideTests`, `ReTranscribeMenuBuilderTests`, `MeetingDetailReTranscribeEngineTests`.

## Tests

- `TranscriptionServiceOverrideTests`: Whisper override with Apple target sends whisper config + .all components + vocab; Apple override with Whisper target sends apple config + .speakerID + empty vocab; nil override uses target; selection unchanged after override job.
- `ReTranscribeMenuBuilderTests`: each disabled-reason row; current marker; order Apple then Whisper; macOS 15 Apple disabled; empty methodId maps to whisper current.
- `MeetingDetailReTranscribeEngineTests`: `reTranscribe(with: .apple)` passes apple config with saved locale; `.whisper` passes whisper config; `currentTranscriptEngine` from methodId; empty/nil methodId maps to whisper; no versions returns nil.
