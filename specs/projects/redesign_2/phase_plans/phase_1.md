---
status: complete
---

# Phase 1: Shared foundations (DesignSystem + data + timing)

## Overview

Build the bottom layer that Phase 2 (Home rebuild) depends on: design tokens,
avatar system, reusable chip/card views, a timing constant, and the DataStore
read-model extension for participants on MeetingSummary. No Home wiring yet.

## Steps

### 1. DesignSystem/Tokens — new palette + type/radii tokens

Add to `Tokens.swift` (arch section 2.1):

- Surface colors: `contentBackground`, `cardFill`
- Line/fill colors: `hairline`, `cardStroke`, `neutralChip`
- Accent washes: `accentWashSoft` (6%), `accentWashStrong` (14%)
- Status: `liveGreen`
- Avatar palette: `avatarPalette` — 16 fixed colors
- Type: greeting (32 bold), soon title (16 semibold), row title (14.5 medium),
  meta (12.5), group label (11.5 semibold uppercase), chip/meet (11)
- Radii: card (12), button/chip (7-8), meet chip (6)
- Spacing: column max width (800), page padding (24/32), hero padding (18),
  row padding (11/14), group-to-card gap (9), card-to-group gap (30),
  stat chip row gap (8)

### 2. Pure helpers — avatarInitials and avatarColorIndex

In a new `DesignSystem/AvatarHelpers.swift`:

- `public func avatarInitials(for name: String) -> String`
  - Two letters: first letter of first token + first letter of last token
  - Single token: first two letters
  - Empty: ""
- `public func avatarColorIndex(forKey key: String, paletteCount: Int = 16) -> Int`
  - FNV-1a 32-bit hash of lowercased+trimmed key
  - Returns `Int(h % UInt32(paletteCount))`
- `public struct AvatarPerson: Hashable, Sendable`
  - `displayName: String`, `email: String?`

### 3. Reusable views — Avatar, AvatarCluster

In a new `DesignSystem/Avatar.swift`:

- `Avatar(person:size:stacked:)` — circle with gradient fill from palette,
  white semibold initials, inset hairline ring, optional 2pt white outer ring
- `AvatarCluster(people:totalCount:size:columnWidth:)` — up to 3 overlapped
  avatars + "+N" badge, fixed 78pt width frame

### 4. Reusable views — StatChip, MeetingPlatformChip, InsetDivider, homeCard, JoinRecordButtonStyle

In new files under DesignSystem:

- `StatChip.swift` — `StatChip(icon:tint:text:)`, neutral pill chip
- `MeetingPlatformChip.swift` — capsule with video.fill + platform label
- `HomeCardModifier.swift` — `.homeCard()` modifier + `InsetDivider`
- `JoinRecordButtonStyle.swift` — filled accent button style

### 5. AppCore — MeetingTiming.joinWindowSeconds

In a new `AppCore/MeetingTiming.swift`:

- `public enum MeetingTiming { static let joinWindowSeconds: TimeInterval = 15 * 60 }`
- Optionally repoint `EventPreviewViewModel.joinWindowSeconds` at it

### 6. DataStore — extend MeetingSummary with participants

In `DataStore+ReadModels.swift`:

- Add `participants: [PersonData]` and `participantCount: Int` to `MeetingSummary`
- Map in `meetingSummaries(...)`: organizer-first, deduped by id, capped at 5

### 7. Tests — AvatarTests

In a new `DesignSystemTests/AvatarTests.swift`:

- `avatarInitials`: "Sam Altman" -> "SA", "Cher" -> "CH", "" -> "",
  "sam@x.com" -> "SA", non-ASCII
- `avatarColorIndex`: deterministic, range 0..<16, case-insensitive,
  whitespace-insensitive, distinct emails differ

### 8. Tests — DataStore read-model participants

In `DataStoreTests/ReadModelTests.swift`:

- `meetingSummaries` returns participants (organizer-first, deduped, <=5)
  and correct participantCount
- Organizer-also-participant counted once
- Zero participants -> [] + 0

## Tests

- `AvatarInitialsTests`: initials extraction for two-word, single-word, empty,
  email-as-name, non-ASCII names
- `AvatarColorIndexTests`: deterministic, range, case/whitespace insensitive,
  distinct keys differ
- `ReadModelParticipantsTests`: organizer-first ordering, dedup, cap at 5,
  participantCount, zero-participant case
