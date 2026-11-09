---
status: complete
---

# UI Design: Import Audio

The visual and layout contract for the drop overlay, the Import screen, the sidebar "Imported" row and the meeting-detail waiting state. Behavior and copy rules are in `functional_spec.md`. Wiring is in `architecture.md`. All values are points.

The design agent's handoff ([`design/design_handoff.md`](design/design_handoff.md), [`design/import_audio_mockups.html`](design/import_audio_mockups.html)) is the north star for layout and composition. **The repo's design system wins on details.** The translation rules are:

| Handoff | Use in the repo |
|---|---|
| IBM Plex Mono | JetBrains Mono: `Font.biscottiMono(_:weight:)` |
| Newsreader 500 | `Font.biscottiSerif(_:)` (NewsreaderDisplay-Medium) |
| SF Pro | system font |
| ink / ink 54% / ink 34% | `Color.ink` / `.inkSecondary` / `.inkTertiary` |
| ink 11% separators | `Color.hairline` |
| ink 5.5% chip fill | `Color.neutralChip` (ink 6%) |
| sage `#4E7D5C` | `Color.sage` (marks, text) |
| sage button gradient | `Color.accentFill` with the `JoinRecordButtonStyle` top highlight |
| sage 12% fill | `Color.softSageFill` |
| card white / `#1A170F` | `Color.cardFill`, with a 0.5pt `Color.cardStroke` border |
| red `#C9402B` (marks) / `#B23320` (text) | `Color.signalRed` (marks) / `Color.signalRedText` (text). The app has one red. |
| paper | `Color.paper` / `Tokens.contentBackground` |
| 16px CSS ring spinner | native `ProgressView().controlSize(.small)` (the app's existing spinner) |
| toolbar title "Import" | dropped: the app has no per-screen toolbar titles |

Dark mode comes for free: every token above is dynamic.

---

## 1. New design-system pieces

Add these to `DesignSystem`.

| Item | Definition | Used by |
|---|---|---|
| `Color.dropVeil` / `Tokens.dropVeil` | `dynamicColor(light: paper @ 0.76, dark: paper-dark @ 0.74)` | drop overlay veil |
| `Color.controlStroke` / `Tokens.controlStroke` | `dynamicColor(light: ink @ 0.16, dark: off-white @ 0.16)` | `BezelButtonStyle` ring |
| `BezelButtonStyle` | see §1.1 | Go to Meeting, Show in Finder |

### 1.1 `BezelButtonStyle`

A small neutral bezel button, the light-chrome sibling of `LightAlertButtonStyle`.
- Label: system 13, weight `.medium`, `Color.ink`. Horizontal padding 12, fixed height 28, `lineLimit(1)`.
- Background: `Color.elevatedFill` in a `RoundedRectangle(cornerRadius: Tokens.buttonRadius)` (8).
- Border: 0.5pt `Color.controlStroke`.
- Shadow: `Tokens.controlShadow`, radius 0.75, y 1 (the same whisper as `LightAlertButtonStyle`).
- Pressed: overlay `Color.neutralChip`. Disabled: opacity 0.5.

---

## 2. Drop overlay

A SwiftUI view layered over the **entire root window content** (`.overlay` on the shell root, `.ignoresSafeArea()`), so it covers the sidebar and detail. The toolbar may stay visible above it; covering the toolbar isn't required. It never takes hits (`.allowsHitTesting(false)`); the AppKit drop view (architecture §6) handles the drag. Window corner clipping comes from the window itself.

### 2.1 Layers

1. **Veil:** `Rectangle().fill(.ultraThinMaterial)` with `Color.dropVeil` on top, filling everything.
2. **Drop zone:** inset **12** on all sides, `RoundedRectangle(cornerRadius: 9)`.
   - Supported: fill `Color.sage.opacity(0.05)`, stroke `Color.sage.opacity(0.70)` with `StrokeStyle(lineWidth: 2, dash: [6, 5])`.
   - Unsupported: no fill, stroke `Color.inkTertiary`, same dash.
3. **Content:** a centered `VStack(spacing: 14)` with `multilineTextAlignment(.center)`.

### 2.2 Content stack

| Element | Spec |
|---|---|
| Tile | 76×76, `RoundedRectangle(cornerRadius: 20)`, then **6** of extra space below (`.padding(.bottom, 6)`). |
| | *Supported:* fill `Color.accentFill`, a 1pt top inner highlight of white @ 0.22 (the `JoinRecordButtonStyle` treatment), shadow `Color.black.opacity(0.14)`, radius 12, y 10. SF Symbol `waveform` at 34pt, weight `.medium`, white. |
| | *Unsupported:* fill `Color.neutralChip`, no shadow, glyph `Color.inkTertiary`. |
| Title | `biscottiSerif(34)`, `.tracking(-0.34)`, `Color.ink`. |
| Subtitle | system 15, `Color.inkSecondary`, `.lineSpacing(5)`, `.frame(maxWidth: 440)`. |
| Format line | `biscottiMono(11.5)`, `.tracking(0.7)`, `Color.inkTertiary`, `.padding(.top, 6)`. Text: `WAV · MP3 · M4A · AAC · AIFF · CAF · FLAC · MP4 · MOV` (middle dots U+00B7). |
| Skip notice | An `HStack(spacing: 8)` in a pill: height 30, horizontal padding 12, `Color.neutralChip` fill, `RoundedRectangle(cornerRadius: Tokens.buttonRadius)`. Icon: SF Symbol `exclamationmark.circle`, 14pt, `Color.inkTertiary`. Text: system 13, `Color.inkSecondary`, with the count in `.semibold` (`Text("\(u)").bold() + Text(" files are unsupported…")`). |

Which elements appear in each state (copy in functional spec §2):

| State | Tile | Title | Subtitle | Format line | Skip notice |
|---|---|---|---|---|---|
| Supported, single | supported | ✓ | "…on your Mac." | ✓ | — |
| Supported, multiple | supported | ✓ | "Each file becomes its own meeting." | — | — |
| Mixed | supported | ✓ | "Each file becomes its own meeting." | — | ✓ |
| Unsupported | unsupported | ✓ | "Biscotti imports audio and video recordings." | ✓ | — |

### 2.3 Motion

- Show and hide with `.transition(.opacity)` inside `withAnimation(.easeOut(duration: 0.14))`.
- Switching between states while hovering (it can't happen in practice, since the drag contents are fixed) has no animation.
- No scale or bounce.

---

## 3. Import screen

The detail pane for route `.importing`. Background `Tokens.contentBackground`.

### 3.1 Layout

- A `ScrollView(.vertical)` with a top-aligned, horizontally centered column: `frame(maxWidth: Tokens.contentColumnMaxWidth)` (620), padding top **72**, bottom **48**, horizontal `Tokens.homeHorizontalPadding` (32).
- Column: `VStack(spacing: 0)`, centered:
  1. **Title:** `biscottiSerif(30)`, `.tracking(-0.3)`, `Color.ink`, centered.
  2. **12** gap, then the **status line**, centered:
     - In progress: `biscottiMono(13)`, `Color.inkSecondary`.
     - Complete: system 15, `Color.inkSecondary`, `.frame(maxWidth: 440)`.
  3. **26** gap (12 + the handoff's 14), then the **list card**, full column width.

### 3.2 List card

- `Color.cardFill` background, 0.5pt `Color.cardStroke` border, `RoundedRectangle(cornerRadius: Tokens.cardRadius)` (12), clipped.
- Rows in a `LazyVStack(spacing: 0)`, with a 0.5pt `Color.hairline` full-width separator between rows (none above the first).
- Use a `LazyVStack` for the rows, since the session list can grow long.

### 3.3 Row

`HStack(spacing: 14)`, height **60**, horizontal padding **16**, vertical content centered.

| Part | Spec |
|---|---|
| Icon tile | 32×32, `RoundedRectangle(cornerRadius: 8)`. *Sage* (converting, done): fill `Color.softSageFill`, `waveform` 14pt `.medium`, `Color.sage`. *Neutral* (waiting, receiving): fill `Color.neutralChip`, glyph `Color.inkTertiary`. *Failed:* fill `Color.signalRed.opacity(0.11)`, SF Symbol `exclamationmark` 13pt `.bold`, `Color.signalRed`. |
| Name / second line | `VStack(alignment: .leading, spacing: 3)`, `frame(maxWidth: .infinity, alignment: .leading)`. Name: system 14, `.medium`, `Color.ink`, `lineLimit(1)`, `.truncationMode(.middle)`. Second line: `biscottiMono(12)`, `Color.inkSecondary`, `lineLimit(1)`. While the date is unresolved, render a single space so the height is reserved. Failed rows instead show system 12, `Color.signalRedText`, `lineLimit(1)`, `.truncationMode(.tail)`. |
| Trailing (`fixedSize()`) | *Waiting:* "Waiting", `biscottiMono(13)`, `Color.inkTertiary`. *Receiving* (file promise not yet delivered): the same as Waiting, but the text is "Receiving…". *Converting:* `HStack(spacing: 9)` { `ProgressView().controlSize(.small)`, "Converting…" system 13 `Color.inkSecondary` }. *Done:* `Button("Go to Meeting")` with `BezelButtonStyle`. *Done, meeting deleted:* "Deleted", system 13, `Color.inkTertiary`. *Failed:* `Button("Show in Finder")` with `BezelButtonStyle`. |

Name display for promised items before delivery: the promised file name if the source app provided one, otherwise "Incoming file". Once delivered, the delivered file's name.

Row date text: `"\(TimeFormatting.shortDate(date)) · \(time)"`, where `time` is the short time style (e.g. "2:14 PM"). Add `TimeFormatting.dateAndTime(_:)` for this so the format lives in one place.

### 3.4 Accessibility

- Each row is one accessibility element: label "‹name›, ‹second line›", value = the trailing state text. The button stays a separate, focusable child.
- The drop overlay posts an accessibility announcement of its title when it appears (`AccessibilityNotification.Announcement`).

---

## 4. Sidebar "Imported" row

- **Position:** in the sidebar footer, between the footer `Divider` and the Settings row: `Divider` → **Imported row** → Settings row. Same horizontal padding (`Tokens.spacingSM`) as Settings. 2pt gap above Settings.
- **Present** only once the import session is non-empty. Then it stays for the life of the process.
- **Built** exactly like `settingsRow`:
  - Icon: SF Symbol `square.and.arrow.down`, `Color.sage` when selected, else `Tokens.secondaryText`.
  - Label: `Text("Imported")` in `.body`, then `Spacer()`.
  - While converting: `ProgressView().controlSize(.mini)`.
  - Vertical padding `Tokens.spacingXS`. Selected background: `Tokens.accentWashStrong` in `RoundedRectangle(cornerRadius: 4)`.
- **Selected** when `route == .importing`.

---

## 5. Meeting detail: waiting state

- **Transcript area:** a queued meeting uses the existing `.processing` presentation, with the message **"Waiting to transcribe…"** and no subtitle.
- **Summary tab pipeline:** while queued, stage 1 reads **"Waiting to transcribe"** with state `.pending` (no spinner). The later stages show as they do today before transcription (`.pending`).
- When the queue starts the job, stage 1 switches to today's "Transcribing" `.active`.
- The **Re-transcribe** menu item and the **Transcribe now** button are disabled while queued.

---

## 6. File menu

- "Import Audio File…" in the **File** menu's import/export group (`CommandGroup(replacing: .importExport)`), with shortcut ⌘⇧I.
- Disabled while onboarding is showing.
- The open panel is the standard sheet on the main window (SwiftUI `.fileImporter`), titled by the system. The prompt button is "Import".
