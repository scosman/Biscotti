# Handoff: Speech to Text Model selection (Apple Speech vs Whisper)

## Overview
Biscotti currently ships one transcription engine (Whisper) and never asks. The next version offers two local engines:

- **Apple Speech**: Apple's `SpeechTranscriber` system API. Its version tracks the OS, and its assets are usually already installed.
- **Whisper**: Whisper V3 Turbo, a 635 MB download.

This handoff adds the choice in two places:
1. **Onboarding → "Download Local AI Models" step.** Transcription and Speaker ID become separate rows. The Transcription row gets a model line plus **See all options ›**, which opens the new sheet.
2. **Settings → AI Enhancements.** Add a new **Speech to Text Model** row with **Manage**, which opens the same sheet.

The sheet is modeled directly on the shipped **AI Language Model** sheet (`ModelManagementUI/ManageModelsSheet.swift`). Reuse its chrome, row matrix, Recommended badge, Default indicator, and bordered small buttons.

## About the design files
The files in this bundle are **design references built in HTML/React**. They are prototypes that show the intended look and behavior; they are not code to ship. Recreate them in the Biscotti SwiftUI codebase (`Packages/BiscottiKit`) using its existing components and tokens: `ModelDownloadRow`, `DownloadControl`, `GrantPill`, `GrantedTag`, `RecommendationLine`, `.homeCard()`, `Tokens.*`, `Color.sage`, and so on.

Open `Speech to Text Model.html` in a browser. It is a pannable canvas, and every artboard is interactive: Download, Choose Model, Delete, the language dropdown, Learn more…, See all options, Manage, and the Custom Vocabulary toggle all work.

Note: `biscotti/stt/sttSheet.jsx` also contains three unused exploration variants (`a`, `c`, `d`). **Only variant `b` is chosen.** Ignore the rest.

## Fidelity
**High fidelity.** Colors, type, and spacing follow the shipped app and the Biscotti tokens. Where a value already exists in code, such as `ManageModelsSheet` or `ModelDownloadCard` metrics, the code value wins over the mock.

---

## 1 · Onboarding: Download Local AI Models
File: `OnboardingUI/ModelDownloadCard.swift`, `OnboardingStepViews.swift`

The title, lead, progress header, footer, and Skip/Continue behavior are **unchanged**.

### Card: now 3 rows (was 2)
The card keeps the same chrome: max width 560, `.homeCard()`, and `InsetDivider(leadingInset: 48)` between rows. The rows are:

| # | Icon (SF Symbol) | Name | Why | Extra line | Trailing |
|---|---|---|---|---|---|
| 1 | `waveform` | **Transcription** | "Turns speech into text." | Model line + See all options › | Download control (below) |
| 2 | `person.2` | **Speaker ID** | "Labels who’s speaking." | none, no options or sheet | Download pill + size caption *(size TBD)* |
| 3 | `sparkles` | **Language Model** | "Meeting summaries, speaker matching, and automatic titles." | Model line + See all options › | unchanged |

Speaker ID is split out of the old "Transcription & Speaker ID" row. It downloads independently, with the same `DownloadControl` states (idle / downloading / ready / failed / insufficientDisk).

### Model line (`RecommendationLine`): change
- **Drop the "Recommended · " prefix in onboarding, on both rows.** Show only the model name, then **See all options ›**.
- Transcription row text:
  - Apple target: **"Apple Speech · {Language} Only"**, e.g. "Apple Speech · English Only".
  - Whisper target: **"Whisper"**.
- Language row text: "Gemma 4 E2B" (the current target name).
- Do **not** show technical names here (no "SpeechTranscriber", no "Whisper V3 Turbo"). Those live only in the sheet.
- Styling is unchanged: SF 12.5, `.inkSecondary`. The link is 12.5 semibold, `.inkSecondary`, with a `chevron.right` at 11.
- Show the line in every state except `.downloading`. This differs from today, which hides it once the row isn't idle. Apple can be READY with zero clicks, so the line must stay visible to keep options discoverable.

### Transcription trailing control (`DownloadControl`)
"Target" means the user's selection if there is one, else the recommended engine.

| Target state | Trailing |
|---|---|
| Apple, assets installed | `GrantedTag("READY")`, with mono 11 `.inkTertiary` caption **"Built in"** beneath. No click needed. |
| Apple, assets not installed | `GrantPill("Download", arrow.down.circle)` + caption **"System download"** |
| Whisper, not downloaded | `GrantPill("Download")` + caption **"~635 MB"** |
| Either, downloading | Existing determinate bar (120 wide, 3pt capsule) + "Downloading… NN%" |
| Either, ready | `GrantedTag("READY")` |

**See all options ›** presents the STT sheet (§2). Choices made in the sheet (engine, language) reflect back into the model line and trailing control.

---

## 2 · Speech to Text Model sheet
New view, sibling to `ManageModelsSheet`. Present it from onboarding (See all options) and from Settings (Manage / Download…).

### Chrome (same as ManageModelsSheet)
- Width **520** (LLM sheet is 480; the trait grid needs a bit more room).
- Padding `Tokens.spacingMD * 1.5` (24). Vertical stack spacing `spacingMD` (16).
- Sheet background is white. The shipped sheet renders white, as in the screenshot.
- Header: **"Speech to Text Model"** (`.headline`, 13 bold).
- Description (`Tokens.metadataFont`, `secondaryText`): **"Choose the model used to transcribe your meetings. Both run entirely on your Mac."**
- Footer: right-aligned **Done** button (`.keyboardShortcut(.cancelAction)`).

### Rows
There are two rows with spacing `spacingSM` (8). Each row has:
- background `Color.neutralChip.opacity(0.5)`, which renders as about `rgba(26,24,19,.035)`
- radius `Tokens.buttonRadius` (8)
- padding **12 / 12 / 10** (a bit roomier than the LLM row's 8)
- inner spacing 9

Row anatomy, top to bottom:
1. **Recommended badge**, shown only on the recommended engine and **placed above the name on its own line**. It is the existing badge: `star.fill` caption2 + "Recommended" caption, sage text, `Capsule` with sage fill at 15% opacity, padding 8/3.
2. **Name line**: HStack of name (13.5 semibold), Spacer, then the selection control:
   - ready + target → `checkmark.circle.fill` (sage) + "Default" (metadata, secondary)
   - ready + not target → `Button("Choose Model")`, bordered, small
   - otherwise nothing
3. **Trait grid**: `LazyVGrid` with 2 flexible columns, spacing 7 rows × 14 columns. Each trait is a 15×15 circle marker plus SF 12.5 text.
   - **Pro**: marker fill sage 14%, `checkmark` glyph 9pt sage, text `.ink`.
   - **Tradeoff**: marker fill `rgba(26,24,19,.06)`, `minus` glyph 9pt at `inkTertiary`, text `.inkSecondary`.
4. **Footer line**: a 0.5pt top hairline (`Color.hairline`) with 8pt padding above. Leading: technical name in IBM Plex Mono 10.5 `inkTertiary`, tracking 0.02em. Trailing: the primary action.

#### Apple Speech row
Traits (in this order, filling the 2×2 grid left→right, top→bottom):
- ✓ **5× faster**
- ✓ **Built in, no download** (if assets installed) / **Built into macOS** (if not installed)
- – **1 language** + inline language dropdown (see below)
- – **No custom vocabulary**

Technical line: `SpeechTranscriber · macOS {major}`, with ` · system download` appended when assets aren't installed.

Primary action (trailing):
- installed → none (system model, so no Delete)
- not installed → `Button("Download")`
- downloading → 120pt progress bar + "NN%" (mono 11)

#### Whisper row
Traits:
- ✓ **Better with jargon & rare words**
- ✓ **Any of 99 languages**
- ✓ **Custom vocabulary**
- – **5× slower**

Technical line: `Whisper V3 Turbo · 635 MB`.

Primary action (trailing):
- not downloaded → `Download`
- downloading → progress
- downloaded → `Delete`, using the existing confirmation dialog pattern ("Delete Whisper?" / "This frees about 635 MB. You can download it again anytime.")

### Apple language dropdown (inline)
Apple transcribes **one** language. Show it as "1 language" followed by an inline **pop-up button** (`Picker` with `.pickerStyle(.menu)`, control size small) whose current value is the language.
- Options (10): Cantonese, Chinese, English, French, German, Italian, Japanese, Korean, Portuguese, Spanish.
- **Initial value comes from the user's locale.** Map `Locale.current.language` to the nearest supported option, and fall back to English.
- Selecting a language updates it immediately. It also updates "Apple Speech · {Language} Only" in onboarding and Settings.
- Persist it as an app setting, e.g. `AppSettings.appleSpeechLanguage`.

### Recommendation
`recommendedSTTEngine` is computed like `ModelSuitability` (hardware/OS conditional; policy TBD). The badge moves to whichever engine is recommended. On macOS 15 the recommendation is always Whisper.

### macOS 15 (SpeechTranscriber unavailable)
- The Apple row content is dimmed to 50% opacity, the same as `blockedReason == .cannotRun`. It has no selection control and no action.
- Its footer line, at full opacity, shows the warning chip **"Requires macOS 26 or later"** (`exclamationmark.triangle.fill` caption2 + caption, `Tokens.warningChipText` on `Tokens.warningChipFill`, capsule). It is followed by a sage plain link button **"Learn more…"** at 12.
- **Learn more…** shows an alert:
  - Title: **"Apple Speech requires macOS 26"**
  - Message: **"This Mac is running macOS 15. Update macOS to use Apple’s built-in speech model. Whisper works on this Mac today."**
  - Buttons: **Not Now** (cancel) and **Software Update…** (default). Software Update… opens `x-apple.systempreferences:com.apple.Software-Update-Settings.extension`.

### Selection behavior
- Default target is the user's selection if set, else recommended.
- **Download** on an engine marks it as the user's choice. When the download finishes it becomes **Default** automatically. *(This differs slightly from the LLM sheet, which requires Choose Model after download. Confirm with design if you prefer strict parity.)*
- **Choose Model** sets the selection.
- **Delete** on the selected Whisper falls back to Apple, if it's available.
- Changing the engine affects **new** transcripts only.

---

## 3 · Settings: AI Enhancements section
File: `SettingsUI/SettingsView.swift` → `aiEnhancementsSection`

Add a row **between "Summary Prompt" and "AI Language Model"**. It matches the existing `aiLanguageModelRow` exactly, with no tint or highlight.

```
HStack {
  VStack(alignment: .leading, spacing: Tokens.spacingXS) {
    Text("Speech to Text Model")
    Text("The model used to transcribe meetings")   // metadataFont, secondaryText
  }
  Spacer()
  if ready {
    Text(apple ? "Apple Speech · \(lang) Only" : "Whisper")  // metadataFont, secondaryText
    Button("Manage") { showSTTSheet = true }.buttonStyle(.bordered).controlSize(.small)
  } else {
    Button("Download…") { showSTTSheet = true }.buttonStyle(.bordered).controlSize(.small)
  }
}
```

### Custom Vocabulary interaction
Custom vocabulary only works with Whisper.
- The Custom Vocabulary section stays **visually unchanged**: no badge and no caption.
- While Apple Speech is the active engine, the **Custom Vocabulary toggle reads off**. Keep the stored preference; just display it off.
- Turning the toggle **on** while Apple is active does not flip it. It shows an alert instead:
  - Title: **"Requires Whisper Transcription"**
  - Message: **"Custom vocabulary only works with the Whisper speech to text model. Switching downloads Whisper (635 MB) and uses it for new transcripts."**
  - Buttons: **Cancel** and **Switch to Whisper** (default).
- **Switch to Whisper** selects Whisper and starts its download if it isn't downloaded yet. It then turns the toggle on.
- With Whisper active, the toggle behaves as it does today.

---

## State (additions)
```swift
enum STTEngine: String { case apple, whisper }
enum STTAvailability { case available, requiresOSUpdate }       // apple only; macOS < 26
// per-engine download state: reuse ModelDownloadState (.notDownloaded / .downloading(fraction) / .downloaded / .failed)
// apple "downloaded" == SpeechTranscriber assets installed (AssetInventory check at launch)

@Published var selectedSTTEngine: STTEngine?        // nil → use recommended
var recommendedSTTEngine: STTEngine                  // hardware/OS policy; .whisper on macOS 15
var sttTarget: STTEngine { selectedSTTEngine ?? recommendedSTTEngine }
@Published var appleSpeechLanguage: String           // default from Locale; one of the 10
```
- Onboarding `transcriptionReady` now means the target engine is ready, so Apple with installed assets counts as ready immediately.
- Speaker ID gets its own readiness and download state, separate from transcription.
- For footer logic, `bothModelsReady` / `bothModelsStarted` become "all three rows".

## Design tokens used
Use the existing `Tokens` and colors, not the hex values.

| Token | Value |
|---|---|
| `.sage` | `#4E7D5C` |
| `.ink` | `#1A1813` |
| `.inkSecondary` | `rgba(26,24,19,.56)` |
| `.inkTertiary` | `rgba(26,24,19,.36)` |
| hairline | `rgba(26,24,19,.11)` |
| `neutralChip` | `rgba(26,24,19,.06)` |
| sage wash (trait marker) | sage at 14% |
| warning chip | ochre text on amber at about 20% (`Tokens.warningChipText` / `warningChipFill`) |

Type:
- SF Pro for UI text.
- IBM Plex Mono (`.biscottiMono`) for technical lines, sizes, and percentages.
- Newsreader (`.biscottiSerif`) for onboarding and Settings titles, which are unchanged.

## Assets
- `Biscotti Design System/brand/app-icon.png`: alert icon. In the app, use the app icon that NSAlert supplies automatically.
- `Biscotti Design System/brand/mark-shield-mic.png`: onboarding footer mark. It already exists in the app.
- Icons are SF Symbols: `waveform`, `person.2`, `sparkles`, `arrow.down.circle`, `checkmark`, `minus`, `checkmark.circle.fill`, `star.fill`, `exclamationmark.triangle.fill`, `chevron.right`.

## Files
- `Speech to Text Model.html`: the canvas. Section 1 is onboarding, section 2 is the sheet, section 3 is Settings.
- `biscotti/stt/sttSheet.jsx`: the sheet. Use `SttRowsB` plus the shared state hook `useSttState`, the language popup `SttLangPop`, and the macOS 15 alert `SttAlert`.
- `biscotti/stt/sttScreens.jsx`: the onboarding step (`SttOnboarding`) and the Settings section (`SttSettings`) with the vocabulary alert.
- `biscotti/design-canvas.jsx`: canvas viewer only. Not part of the design.

## Open items
- Speaker ID download size. The mock shows "size TBD".
- The Apple asset download size, when assets aren't installed. The mock shows only "System download".
- The recommendation policy (hardware/OS rules).
