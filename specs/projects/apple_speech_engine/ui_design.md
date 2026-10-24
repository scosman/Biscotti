---
status: complete
---

# UI Design: Apple Speech Engine

Visual reference: `design_handoff/Speech to Text Model.html` (sheet variant **B** only; ignore variants A, C, D). Behavior: `functional_spec.md`. Where a value exists in code, the code value wins over the mock. All new UI uses existing components and tokens (`Tokens.*`, `.sage`, `.ink*`, `Color.neutralChip`, `Color.hairline`, `GrantPill`, `GrantedTag`, `DownloadControl`, `RecommendationLine`, `.homeCard()`, `InsetDivider`, `.biscottiMono`).

## 1. Surfaces and Navigation

```
Onboarding ─ Download Local AI Models ─┬─ Transcription row ─ "See all options ›" ─► Speech to Text Model sheet
                                       │                       (hidden on macOS 15 / Apple unavailable)
                                       ├─ Speaker ID row (no sheet)
                                       └─ Language Model row ─ "See all options ›" ─► AI Language Model sheet (unchanged)

Settings ─ AI Enhancements ─ "Speech to Text Model" row ─ Manage / Download… ─► Speech to Text Model sheet
Settings ─ Custom Vocabulary ─ toggle ─► "Requires Whisper Transcription" alert (when Apple is target)
Speech to Text Model sheet ─ Choose Model / Download on Apple ─► "Turn Off Custom Vocabulary?" alert (when vocab on)
Speech to Text Model sheet ─ Apple "Learn more…" (macOS 15) ─► "Apple Speech requires macOS 26" alert
Speech to Text Model sheet ─ Whisper Delete ─► delete confirmation dialog
```

## 2. Speech to Text Model Sheet

New view in `ModelManagementUI`, sibling to `ManageModelsSheet`. Same chrome:

| Item | Value |
|---|---|
| Width | **520** (LLM sheet: 480) |
| Padding | `Tokens.spacingMD * 1.5` |
| Stack spacing | `Tokens.spacingMD` |
| Header | "Speech to Text Model", `.headline` |
| Description | "Choose the model used to transcribe your meetings. Both run entirely on your Mac.", `Tokens.metadataFont`, `Tokens.secondaryText` |
| Rows | Apple Speech, then Whisper; spacing `Tokens.spacingSM` |
| Footer | Right-aligned **Done**, `.keyboardShortcut(.cancelAction)` |
| Delete dialog | `confirmationDialog`, same as LLM sheet |

### 2.1 Row anatomy (variant B)

Row container: background `Color.neutralChip.opacity(0.5)`, `RoundedRectangle(cornerRadius: Tokens.buttonRadius)`, padding **12 top / 12 horizontal / 10 bottom**, vertical spacing **9**.

Top to bottom:

1. **Recommended badge** (recommended engine only), on its own line above the name. Reuse the LLM sheet's badge (star.fill caption2 + "Recommended" caption, sage on sage 15% capsule, padding 8/3). Extract it so both sheets share one view.
2. **Name line:** `HStack { name; Spacer(); selectionControl }`. Name 13.5 semibold.
   - Ready + target → `checkmark.circle.fill` (sage) + "Default" (`metadataFont`, `secondaryText`). Same view as the LLM sheet.
   - Ready + not target → `Button("Choose Model")`, `.bordered`, `.small`.
   - Otherwise → nothing.
3. **Trait grid:** `LazyVGrid`, 2 flexible columns, spacing 7 (rows) × 14 (columns). Each trait: 15×15 circle marker + text 12.5.
   - Pro: marker fill sage 14%, `checkmark` 9pt sage; text `.ink`.
   - Tradeoff: marker fill `Color.neutralChip`, `minus` 9pt `.inkTertiary`; text `.inkSecondary`.
4. **Progress / failure (when present)** — the LLM sheet's left-column pattern, full row width:
   - Determinate (Apple): `ProgressView(value:)` + "Downloading… N%" (`metadataFont`, `secondaryText`).
   - Indeterminate (Whisper): `ProgressView().controlSize(.small)` + "Downloading…".
   - Failed: "Download failed: {message}" in `.signalRedText`; primary action becomes **Retry**.
   - Insufficient disk (Whisper, not downloaded): warning chip "Insufficient free space on disk" (LLM chip); Download disabled.
5. **Footer line:** 0.5pt top hairline (`Color.hairline`) with 8pt above the content. `HStack { technical line; Spacer(); primaryAction }`.
   - Technical line: `.biscottiMono(10.5)`, `.inkTertiary`, tracking 0.02em.
   - Primary action: `.bordered`, `.small` (Download / Retry / Delete), or nothing.
   - While any download is in flight, the other row's **Download** is disabled (LLM rule). No action shows on the downloading row.

### 2.2 Apple Speech row

| Element | Content |
|---|---|
| Traits (order: left→right, top→bottom) | ✓ "5× faster" · ✓ "Built in, no download" (Apple ready) / "Built into macOS" (not ready) · – "1 language" + locale pop-up · – "No custom vocabulary" |
| Locale pop-up | `Picker` with `.pickerStyle(.menu)`, `.controlSize(.small)`, label hidden; the current value shows the language + region display name. Options: runtime supported locales, sorted by display name. |
| Technical line | "SpeechTranscriber · macOS {major}"; append " · system download" when not ready |
| Primary action | Not ready → **Download**; downloading → none (progress shows in the row); ready → none (no Delete) |

**Apple unavailable** (macOS 15, or `isAvailable` false):
- Badge, name line and trait grid render at **50% opacity** (LLM `.cannotRun` pattern). No selection control, no pop-up (the trait reads "1 language" as text), no action.
- Footer at full opacity, leading side: warning chip (LLM chip style) **"Requires macOS 26 or later"** + plain sage link button **"Learn more…"** (12pt). When macOS ≥ 26 but unavailable: chip **"Not available on this Mac"**, no link.

### 2.3 Whisper row

| Element | Content |
|---|---|
| Traits | ✓ "Better with jargon & rare words" · ✓ "Any of 99 languages" · ✓ "Custom vocabulary" · – "5× slower" |
| Technical line | "Whisper V3 Turbo · 626 MB" |
| Primary action | Not downloaded → **Download**; downloading → none; failed → **Retry**; downloaded → **Delete** |

### 2.4 Sheet alerts

| Trigger | Title | Message | Buttons |
|---|---|---|---|
| Apple "Learn more…" | Apple Speech requires macOS 26 | This Mac is running macOS {major}. Update macOS to use Apple’s built-in speech model. Whisper works on this Mac today. | **Not Now** (cancel) · **Software Update…** (default; opens `x-apple.systempreferences:com.apple.Software-Update-Settings.extension`) |
| Choose Model / Download on Apple while effective custom vocabulary is on | Turn Off Custom Vocabulary? | Apple Speech doesn't support custom vocabulary. You need to disable it to switch models. | **Cancel** · **Turn Off and Switch** (default) |
| Whisper Delete | Delete Whisper? | This frees about 626 MB. You can download it again anytime. + (when vocab on and Apple becomes target) " Custom vocabulary turns off until you switch back to Whisper." | **Delete** (destructive) · Cancel |

Alerts use SwiftUI `.alert` (the app icon is supplied by the system). The delete dialog uses `confirmationDialog` like the LLM sheet.

## 3. Settings → AI Enhancements

New row **"Speech to Text Model"** between `summaryPromptRow` and `aiLanguageModelRow`. It copies `aiLanguageModelRow` exactly:

```
HStack {
  VStack(alignment: .leading, spacing: Tokens.spacingXS) {
    Text("Speech to Text Model")
    Text("The model used to transcribe meetings")        // metadataFont, secondaryText
  }
  Spacer()
  if targetReady {
    Text(summaryLabel)                                     // metadataFont, secondaryText
    Button("Manage") { showSTTSheet = true }               // .bordered, .small
  } else {
    Button("Download…") { showSTTSheet = true }            // .bordered, .small
  }
}
```

- `summaryLabel`: "Apple Speech · {Language} Only" or "Whisper".
- Not affected by the "AI Analysis & Summary" toggle (transcription always runs).
- On macOS 15 the sheet opens with the Apple row disabled (§2.2).

## 4. Settings → Custom Vocabulary

Visually unchanged (no badge, no caption).
- The master toggle's displayed value is the **effective** custom vocabulary (off while Apple is the target). Rows 2–3 hide when it reads off (existing behavior).
- Turning it on while Apple is the target does not flip it; it shows:

| Title | Message | Buttons |
|---|---|---|
| Requires Whisper Transcription | Custom vocabulary only works with the Whisper speech to text model. Switching downloads Whisper (626 MB) and uses it for new transcripts. *(Whisper already downloaded: "Custom vocabulary only works with the Whisper speech to text model. Switching uses Whisper for new transcripts.")* | **Cancel** · **Switch to Whisper** (default) |

- **Switch to Whisper** → selection `whisper`, Whisper download starts if needed (progress is visible in the sheet and the Settings row shows "Download…" until ready), preference on, toggle reads on, child rows appear.

## 5. Onboarding → Download Local AI Models

Title, lead, progress header, footer chrome and Skip/Continue placement are unchanged. Card: max width 560, `.homeCard()`, `InsetDivider(leadingInset: 48)` between rows. Uses `ModelDownloadRow` + `DownloadControl` for all three rows.

| # | Icon | Name | Why | Extra line | Trailing (`DownloadControl`) |
|---|---|---|---|---|---|
| 1 | `waveform` | Transcription | "Turns speech into text." | `RecommendationLine`: target summary label + "See all options ›" | See §5.1 |
| 2 | `person.2` | Speaker ID | "Labels who’s speaking." | none | idle "~11 MB" / indeterminate progress / READY / failed / disk |
| 3 | `sparkles` | Language Model | unchanged | `RecommendationLine` without the "Recommended · " prefix | unchanged |

### 5.1 Transcription row

- **Extra line** (`RecommendationLine`, no "Recommended · " prefix): "Apple Speech · {Language} Only" or "Whisper".
  - Shown in every state except downloading (differs from today's language row, which shows it only when idle; Apple can be READY with no click).
  - **"See all options ›" hidden on macOS 15 / Apple unavailable**: the line shows only "Whisper". `RecommendationLine` gets an option to hide the link.
- **Trailing control:**

| Target state | Control |
|---|---|
| Apple ready | `GrantedTag("READY")` + caption **"Built in"** (`.biscottiMono(11)`, `.inkTertiary`) |
| Apple not ready | Download pill + caption **"System download"** |
| Apple installing | determinate bar + "Downloading… N%" (existing determinate state) |
| Whisper not downloaded | Download pill + caption **"626 MB"** |
| Whisper downloading | indeterminate bar + stage text (existing) |
| Whisper ready | `GrantedTag("READY")` |
| Failed / insufficient disk | existing states |

- Choices in the sheet (engine, locale) update this row live.
- `ModelRowState` gets a ready variant with an optional caption (for "Built in").

### 5.2 Footer

- Continue shows when all three rows are ready or started (was two). Otherwise Skip.
- Clicking Continue saves the target engine if the selection is empty (functional spec §4.3).

## 6. States Checklist (for tests)

Sheet rows: {Apple, Whisper} × {available, unavailable(15), unavailable(26)} × {not ready, downloading(fraction/nil), failed, ready} × {target, not target} × {recommended, not}; Whisper also insufficient disk. Onboarding transcription row: each target state in §5.1, plus macOS 15 (no link). Settings row: ready/not ready × engine. Alerts: each trigger in §2.4 and §4, with vocab on/off and Whisper downloaded/not.
