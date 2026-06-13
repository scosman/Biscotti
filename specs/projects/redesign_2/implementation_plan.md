---
status: complete
---

# Implementation Plan: redesign_2 — Design Project 1 (App Container + Home)

Two phases: build the shared parts (with unit tests), then assemble Home.
Details live in `functional_spec.md` and `architecture.md`; this is the ordered
checklist.

## Phases

- [x] **Phase 1 — Shared foundations (DesignSystem + data + timing).**
  Bottom layer everything else uses; no Home wiring yet.
  - `DesignSystem/Tokens`: add palette + type/radii tokens (arch §2.1), incl.
    the fixed 16-color `avatarPalette`.
  - Pure helpers `avatarInitials` / `avatarColorIndex` (FNV-1a, stable across
    launches) + `AvatarPerson` (arch §2.2).
  - Reusable views: `Avatar`, `AvatarCluster`, `StatChip`,
    `MeetingPlatformChip`, `InsetDivider`, `homeCard()` modifier,
    `JoinRecordButtonStyle` (arch §2.2–2.3) — with `#Preview`s.
  - `AppCore`: add `MeetingTiming.joinWindowSeconds` (arch §4); optionally
    repoint `EventPreviewViewModel` at it.
  - `DataStore`: extend `MeetingSummary` with `participants` (organizer-first,
    deduped, ≤5) + `participantCount`; map in `meetingSummaries(...)` (arch §3).
  - Tests: `AvatarTests` (initials/color-index) + DataStore read-model tests.

- [x] **Phase 2 — Home rebuild (ViewModel + View + wiring).**
  Assemble the parts into the redesigned Home; container background.
  - `HomeViewModel`: `urlOpener` injection; `greeting`/`dateText`; stat-chip
    derivations (`meetingsLeftText`/`nextInText`/`showStatChips`);
    hero detection (`heroEvent`/`heroIsRecordOnly`/`recordDisabled`); avatar +
    `pastSecondLine` mapping; actions `joinAndRecord`/`openInCalendar`
    (arch §5).
  - `HomeView`: rebuild to `agent_spec.md` §4 — `#FBFBFC` background, 800-wide
    vertically-centered column, manual Upcoming/Past cards, hero row, avatars,
    stat chips, "See all ›", re-skinned empty/permission states (arch §6).
  - `AppShellViewModel`: inject `urlOpener: { NSWorkspace.shared.open($0) }`
    into `HomeViewModel`.
  - Tests: extend `HomeViewModelTests` (greeting, chips, hero, actions,
    mapping — arch §8).
