# Phase 3 Review Packet: Dark Mode Visual Review

This packet lists every dark-mode decision, surface by surface, so the human
reviewer can evaluate each one in situ. For each surface the packet names the
tokens that appear there, flags the judgment calls and deliberate simplifications,
and gives a concrete "what to check" prompt.

Automated screenshots were **not captured** (see the note at the end). A manual
capture/review script is provided instead.

---

## Token quick-reference (dark hex values)

For easy cross-referencing while reviewing. Light values are unchanged from the
pre-dark-mode codebase.

| Token | Dark value | Role |
|---|---|---|
| `paper` | `#100E09` | content/pane background |
| `wall` | `#110F09` | window backdrop (flat) |
| `sidebarTint` | `#14120D @ 74%` | sidebar overlay tint |
| `cardFill` | `#1A170F` | card surfaces |
| `cardStroke` | `#F7F2E8 @ 12%` | card border hairline |
| `ink` | `#F7F2E8` | primary text |
| `inkSecondary` | `#F7F2E8 @ 58%` | secondary/meta text |
| `inkTertiary` | `#F7F2E8 @ 36%` | tertiary text, chevrons |
| `hairline` | `#F7F2E8 @ 12%` | separators |
| `neutralChip` | `#F7F2E8 @ 7%` | neutral chip fill |
| `sage` | `#86C295` | accent text/icon/link |
| `accentFill` | `#56906A` | button fills (white label) |
| `accentTrack` | `#5E9A6F` | progress bar fills |
| `accentWashSoft` | `#86C295 @ 12%` | hero tint, speaker chips |
| `accentWashStrong` | `#86C295 @ 16%` | selection wash |
| `softSageFill` | `#86C295 @ 14%` | "Add note" button fill |
| `read` | `#F7F2E8 @ 75%` | long-form body text |
| `elevatedFill` | `#1A170F` | white-button/field fills |
| `signalRed` | `#E5604A` | red marks/dots/icons/fills |
| `signalRedText` | `#F08A78` | standalone red text labels |
| `recordingOutline` | `#E5604A @ 36%` | Stop/REC button border |
| `recordingTintSoft` | `#E5604A @ 8%` | auto-stop card wash |
| `warningOchre` | `#E8A13A` | warning icons, pulsing dot |
| `warningChipText` | `#F0C04A` | amber text (kicker + value) |
| `warningChipFill` | `#E8A13A @ 15%` | amber chip background |
| `cardShadow` | `black @ 40%` | home card shadow |
| `controlShadow` | `black @ 40%` | light-alert button shadow |
| `findHighlightFocused` | `#86C295 @ 35%` | current find match |

---

## Surface-by-surface review

### 1. Home

**Tokens landing here:**
- `paper` (`#100E09`) -- full-pane background via `Tokens.contentBackground`
- `ink` (`#F7F2E8`) -- greeting serif title
- `inkSecondary` (`#F7F2E8 @ 58%`) -- date line (mono)
- `cardFill` (`#1A170F`) -- card backgrounds via `HomeCardModifier`
- `cardStroke` (`#F7F2E8 @ 12%`) -- card border hairlines
- `cardShadow` (`black @ 40%`) -- card whisper shadow
- `neutralChip` (`#F7F2E8 @ 7%`) -- stat chips
- `accentWashSoft` (`#86C295 @ 12%`) -- hero "starting soon" row tint
- `sage` (`#86C295`) -- timestamps, "Join & Record" text accents, meet chip icons
- `accentFill` (`#56906A`) -- "Join & Record" / "Record" button fills
- `hairline` (`#F7F2E8 @ 12%`) -- inset dividers between rows
- `inkTertiary` (`#F7F2E8 @ 36%`) -- chevrons, meta separators
- Avatars: **unchanged** (colorful palette, white initials, white rings)

**Judgment calls to scrutinize:**
- **Flat wall (skipped comp gradient):** The window backdrop is flat `wall`
  `#110F09`. The design comp used a radial gradient; we kept the code's flat fill
  and ported only the midpoint dark value. *Check:* does the flat dark backdrop
  feel too uniform, or does the card elevation provide enough visual structure?
- **Flat cards (skipped comp gradient):** Cards are flat `cardFill` `#1A170F`. The
  comp had a subtle `card -> cardTop` gradient. *Check:* do flat dark cards read
  as properly elevated against the `#100E09` paper?
- **Card shadow at 40%:** Light shadow is `black @ 5%`. Dark bumps to `black @ 40%`
  per design. On a near-black surface, even 40% black shadow is subtle. *Check:*
  is the shadow visible enough, or is the card hairline doing all the lifting?

**What to check:**
- Greeting title legibility (serif `ink` on `paper`).
- Stat chips: `neutralChip` fill visible against `paper`?
- Hero row: `accentWashSoft` tint differentiates the row from plain cards?
- Avatar colors read well against `cardFill`; white initials/rings still pop?
- Card elevation: `cardFill` vs `paper` -- enough contrast to see the card lift?
- "Join & Record" button: white label on `accentFill` `#56906A` -- sufficient
  contrast? (Should be AA-large at weight >= 500.)

---

### 2. Meeting Detail (transcript + notes)

**Tokens landing here:**
- `paper` -- pane background
- `ink` -- meeting title, notes body, speaker names (palette colors override for
  identified speakers)
- `inkSecondary` -- submeta text, source pill text, "Open in Calendar" meta
- `inkTertiary` -- timestamps (mono), dot separators
- `read` (`#F7F2E8 @ 75%`) -- **transcript utterance body text**
- `sage` -- clickable links ("Open in Calendar"), speaker timestamps in playback
- `cardFill` / `cardStroke` -- any card surfaces
- `accentWashSoft` -- speaker chip backgrounds
- `accentWashStrong` (`#86C295 @ 16%`) -- selection wash, find-match background
- `findHighlightFocused` (`#86C295 @ 35%`) -- current find-match highlight
- `neutralChip` -- source pill fill
- `hairline` -- dividers
- `.ultraThinMaterial` (pinned transport bar) -- native, adapts automatically
- `elevatedFill` (`#1A170F`) -- focused title field background
- Segmented `Picker`, `Slider`, `.destructive` Delete, "..." `Menu` -- all **native**

**Judgment calls to scrutinize:**
- **`read` token (the main one):** Transcript body was `inkSecondary` (54% alpha);
  dark bumps to 75% alpha (`#F7F2E8 @ 75%`). This is the primary reason the
  `read` token exists -- sustained reading comfort. *Check:* does the `read`
  token at 75% provide comfortable reading contrast against `paper` `#100E09`
  without being too bright (fatiguing)? Is the visual hierarchy clear between
  `read` (75%), `inkSecondary` (58%), and `inkTertiary` (36%)?
- **Flat progress tracks (skipped comp gradient):** The audio `Slider` tint stays
  at bright `sage` `#86C295` per design ("its tint is accent(text-bright)"). The
  Slider rail is native. *Check:* does the bright sage tint read well on the
  native dark Slider rail?

**What to check:**
- Transcript text (`read`) legibility against dark `paper` for sustained reading.
- Speaker names in their palette colors -- do they still pop on the dark card?
- Timestamps (`inkTertiary` @ 36%) -- readable but receded?
- Notes tab: `ink` body text in the MarkdownEditor (AppKit, uses `NSColor.ink`
  and `NSColor.inkSecondary` -- should auto-adapt via dynamic NSColor).
- Find/replace highlights: `accentWashStrong` and `findHighlightFocused` visible?
- Source pill: `neutralChip` fill + `inkSecondary` text on dark.
- Segmented control, Slider, Delete button, "..." menu: native dark adaptation correct?
- Focused title field: `elevatedFill` background + `sage` border visible?

---

### 3. Active Recording

#### 3a. RECORDING badge + Stop & Save button

**Tokens landing here:**
- `signalRed` (`#E5604A`) -- pulsing dot fill, ripple ring stroke, stop-square icon
- `signalRedText` (`#F08A78`) -- "RECORDING" label text
- `elevatedFill` (`#1A170F`) -- Stop & Save button fill (was white)
- `recordingOutline` (`#E5604A @ 36%`) -- Stop & Save button border
- `controlShadow` (`black @ 40%`) -- button shadow

**Judgment calls to scrutinize:**
- **`signalRedText` split (judgment call #1):** The "RECORDING" label uses the
  lighter `#F08A78` instead of the mark red `#E5604A`. The mark red is ~4.5:1
  contrast on dark (borderline AA); `signalRedText` is ~7:1. *Check:* does
  `#F08A78` look harmonious next to the `#E5604A` dot, or does the lighter text
  feel disconnected from the recording state?
- **Flat record pill (skipped comp gradient):** The comp showed a red gradient
  (`alertGrad`) for the recording pill. The code uses flat `elevatedFill` + red
  text/icon via `LightAlertButtonStyle`. *Check:* does the flat elevated-fill
  Stop & Save button read correctly as the primary recording action?
- **`elevatedFill` = `cardFill`:** Both resolve to `#1A170F` in dark. The
  Stop & Save button fill is the same color as a card. *Check:* does the
  `recordingOutline` border provide enough distinction?

**What to check:**
- "RECORDING" badge: dot + text alignment; `signalRedText` legibility on `paper`.
- Stop & Save: white stop-square icon visible on `elevatedFill`? Wait -- the icon
  uses `signalRed` (`foregroundStyle(Color.signalRed)` from `LightAlertButtonStyle`).
  Is the red icon + red label readable on the dark card-colored button?
- Ripple animation rings: `signalRed` stroke visible against `paper`?
- Button shadow: `controlShadow` at 40% -- visible or irrelevant on dark?

#### 3b. REC pill (toolbar header)

**Tokens landing here:**
- `elevatedFill` -- pill fill
- `recordingOutline` -- pill border
- `signalRed` -- pulsing dot inside the pill
- Mono timer text uses `signalRed` (via `LightAlertButtonStyle` foreground)

**What to check:**
- REC pill in the toolbar area: does it stand out against the window chrome?
- Timer text legibility (mono `signalRed` on `elevatedFill`).

#### 3c. Time chips (Elapsed + amber warning)

**Tokens landing here:**
- Elapsed chip: `neutralChip` (`#F7F2E8 @ 7%`) fill, `inkTertiary` kicker, `ink` value
- Warning chip (LEFT <= 5:00 / OVER): `warningChipFill` (`#E8A13A @ 15%`) fill,
  `warningChipText` (`#F0C04A`) for kicker AND value, `warningOchre` (`#E8A13A`) dot

**Judgment calls to scrutinize:**
- **Amber non-split (judgment call #3):** The design split amber text into kicker
  (`#D9A53A`) and value (`#F0C04A`). We use one token `warningChipText` at the
  brighter `#F0C04A` for both. *Check:* is the "LEFT" / "OVER" kicker too bright
  at `#F0C04A` (the comp wanted `#D9A53A` there), or does the unified bright
  amber read well?
- **Amber chip fill at 15%:** The comp used 18% for the wash; code uses 15%
  (matching the existing `warningBackground` opacity). *Check:* is the amber chip
  fill visible enough at 15% against `paper`, or should it be bumped?

**What to check:**
- Elapsed chip: `neutralChip` fill visible against `paper`? Mono value text clear?
- Warning chip: amber text `#F0C04A` legible against `warningChipFill` `#E8A13A @ 15%`
  on `paper`? The chip should be visually distinct from the neutral Elapsed chip.
- Pulsing amber dot (`warningOchre` `#E8A13A`) visible and animated?

#### 3d. Note composer + notes list

**Tokens landing here:**
- `softSageFill` (`#86C295 @ 14%`) -- "Add note" button fill
- `sage` -- note timestamps
- `ink` -- note body text
- `inkSecondary` -- note meta
- `hairline` -- divider above composer

**What to check:**
- "Add note" button: `softSageFill` visible against `paper`?
- Note timestamps in `sage` -- differentiated from body `ink`?

#### 3e. Auto-stop countdown card

**Tokens landing here:**
- `cardFill` + `recordingTintSoft` (`#E5604A @ 8%`) -- card fill with red wash overlay
- `cardStroke` + `recordingOutline` -- double-border
- `ink` -- "Auto-stopping soon" heading
- `signalRedText` (`#F08A78`) -- countdown seconds text
- `signalRed` -- countdown progress bar fill
- `neutralChip` -- progress bar track, "Keep Recording" button fill
- `hairline` -- "Keep Recording" button border

**What to check:**
- Card red wash: is `recordingTintSoft` (8% of `#E5604A`) visible on `cardFill`?
- Countdown seconds in `signalRedText` -- legible on the washed card?
- Progress bar: `signalRed` fill on `neutralChip` track -- visible?

---

### 4. Upcoming Event detail

**Tokens landing here:**
- `paper` -- pane background
- `cardFill` / `cardStroke` -- event cards
- `ink` / `inkSecondary` / `inkTertiary` -- text hierarchy
- `sage` -- links, toggles (on state), disclosure triangles (native)
- `accentWashSoft` -- auto-record card tint
- Destructive menu items: native (`.destructive` role)

**What to check:**
- Event detail card elevation on `paper`.
- Auto-record card: `accentWashSoft` tint visible on `cardFill`?
- Native controls (toggles, disclosure triangles, destructive items) -- correct
  dark adaptation?

---

### 5. Onboarding

**Tokens landing here:**
- `paper` -- full background
- `ink` -- serif titles ("Welcome to Biscotti", "Grant access")
- `inkSecondary` -- subtitle text, description text
- `accentFill` (`#56906A`) -- "Continue" / "Get Started" / "Download" CTA buttons
- `accentTrack` (`#5E9A6F`) -- progress bar fill (3 sites: `ProgressHeader`,
  `ModelDownloadCard` indeterminate bar, `ModelDownloadCard` determinate bar)
- `hairline` -- progress bar track, dividers
- `accentWashSoft` -- permission icon tile fill
- `sage` -- permission icon foreground, "GRANTED" tag text, sage links
- `accentFill` -- "GRANTED" tag circle fill, "Grant" pill buttons
- `signalRedText` (`#F08A78`) -- download-failed error message
- `warningOchre` -- insufficient-disk warning icon + text

**Judgment calls to scrutinize:**
- **`accentTrack` split (judgment call #2):** Progress bar fills use `#5E9A6F`
  instead of bright `sage` `#86C295`. The design wanted fills a touch less bright
  than text. *Check:* does `#5E9A6F` read as a filled progress bar against the
  `hairline` (`#F7F2E8 @ 12%`) track on dark `paper`? Or is it too dim?
- **Flat progress tracks (skipped comp gradient):** The comp showed gradient
  progress fills. Code uses flat `accentTrack`. *Check:* do flat sage progress
  bars look intentional, not broken?

**What to check:**
- Progress header bar: `accentTrack` fill vs `hairline` track -- enough contrast?
- CTA button: white label on `accentFill` `#56906A` -- legible? White sheen
  gradient overlay still works on the darker fill?
- Permission cards: `accentWashSoft` icon tiles visible on `cardFill`?
- "GRANTED" tag: `accentFill` circle + white checkmark visible?
- Error text (`signalRedText`) legible in the download-failed state?
- Indeterminate bar animation: `accentTrack` segment on `hairline` track?

---

### 6. Settings

**Tokens landing here:**
- `paper` (`Tokens.contentBackground`) -- full background
- Native `Form` / `.grouped` -- sections, toggles, pickers, buttons all native
- `sage` -- debug section links ("Replay Onboarding", "Clear Selected LLM")
- `inkSecondary` (`Tokens.secondaryText`) -- description captions
- `warningOchre` -- permission warning icons (exclamation triangle)
- `warningChipText` + `warningChipFill` -- "Requires Calendar Access" badge
- Calendar row: `Color(hex:)` calendar dots -- **unchanged** (data colors)
- `.bordered` buttons ("Request Access", "Open Settings", "Manage") -- native

**What to check:**
- Native form sections render correctly on `paper` background in dark?
- Toggle controls, segmented pickers, bordered buttons -- all native dark?
- Warning icons (`warningOchre`) visible?
- "Requires Calendar Access" amber badge: `warningChipText` on `warningChipFill`
  legible?
- Calendar color dots: data colors still visible on dark form row backgrounds?

---

### 7. Model management sheets (ManageModelsSheet)

**Tokens landing here:**
- Native sheet chrome -- adapts automatically
- `ink` -- model names, headings
- `inkSecondary` (`Tokens.secondaryText`) -- descriptions, downloading status
- `signalRedText` (`#F08A78`) -- "Download failed: ..." error text
- `warningOchre` -- insufficient-disk warnings
- Native buttons, pickers, progress views

**What to check:**
- Sheet background: native dark sheet chrome?
- Error text (`signalRedText`) legibility within the sheet context.
- All native controls (buttons, progress indicators) adapt correctly?

---

### 8. Error + warning banners

**Tokens landing here:**
- Warning banner: `warningOchre` icon + `warningBackground` (`#E8A13A @ 15%`) fill
  + `inkSecondary` message text
- Error banner: `signalRed` icon + `errorBackground` (`#E5604A @ 15%`) fill
  + `inkSecondary` message text
- `.borderless` action button -- native

**What to check:**
- Warning banner: `warningOchre` icon visible on `warningBackground` fill? The
  fill is `warningOchre` at 15% -- does it read as a tinted background strip?
- Error banner: `signalRed` icon visible on `errorBackground` fill?
- Banner message text (`inkSecondary`) legible on the tinted fill?
- Banner fills visible against `paper`?

---

### 9. Menu-bar popover

**Tokens landing here:**
- This is a **`.menu`-style `MenuBarExtra`** -- entirely native menu items
  (`Button`, `Divider`, `Text`). No custom views, no custom colors.

**What to check:**
- The menu uses standard macOS menu rendering. Confirm it appears as a native
  dark menu with no custom color artifacts.
- "Start Recording" / "Stop Recording", "Open Biscotti", "Quit Biscotti" --
  all standard menu items, should adapt automatically.

---

### 10. Markdown editor (AppKit NSTextView)

**Tokens landing here:**
- `NSColor.ink` (dynamic) -- body text color via `MarkdownEditorTheme.bodyText`
- `NSColor.inkSecondary` (dynamic) -- muted/heading-marker/strikethrough text,
  placeholder text
- `NSColor.inkTertiary` (dynamic) -- disabled text
- `NSColor.sage` (dynamic) -- links
- `NSColor.accentWashStrong` (dynamic) -- find-match highlight
- `NSColor.findHighlightFocused` (dynamic) -- current find-match highlight

**Judgment calls to scrutinize:**
- **NSColor dynamic resolution:** The `MarkdownEditorConfiguration+Biscotti`
  passes NSColor-backed tokens into the theme. These should resolve via the
  window's `effectiveAppearance`. *Check:* does the editor re-render correctly
  on a **live** Light -> Dark toggle (no relaunch)?

**What to check:**
- Body text (`ink`) legibility in the editor.
- Placeholder text (`inkSecondary`) visible but receded?
- Links (`sage`) visible and clickable-looking?
- Find highlights: both wash and focused highlight visible?
- **Live appearance switch:** toggle System Settings while the editor is visible
  -- text colors update without closing the editor?

---

## Consolidated judgment-call checklist

These are the decisions the reviewer should explicitly approve or request changes to:

| # | Decision | Where to look | Alternatives if rejected |
|---|---|---|---|
| 1 | **`signalRedText` split** (`#F08A78` for text vs `#E5604A` for marks) | RECORDING label, auto-stop seconds, "Remove association", download-failed messages | Drop the token; let all red text use `signalRed` `#E5604A` (~4.5:1 on dark) |
| 2 | **`accentTrack` split** (`#5E9A6F` for progress fills vs `#86C295` for text) | Onboarding progress bar, model download bars | Drop the token; let progress bars use `sage` `#86C295` |
| 3 | **Amber non-split** (one `warningChipText` `#F0C04A` for both kicker + value) | Warning time chips (LEFT/OVER) | Split into two tokens: kicker `#D9A53A`, value `#F0C04A` |
| 4 | **Flat window wall** (no radial gradient) | Entire app backdrop | Add a radial gradient (new code, not just a token) |
| 5 | **Flat cards** (no top-to-bottom gradient) | All card surfaces (home, recording, onboarding) | Add `cardTop` gradient (new code) |
| 6 | **Flat record pill/button** (no `alertGrad` gradient) | Stop & Save, REC pill | Add a red gradient fill (new code) |
| 7 | **Flat progress tracks** (no gradient fills) | Onboarding progress, model download bars | Add gradient fills (new code) |
| 8 | **`elevatedFill` = `cardFill`** (same `#1A170F` value) | Stop & Save button, REC pill, focused title field | Use a lighter elevated value like `#211D14` |

Items 4-7 are the "skipped comp elements" from functional-spec section 3.6 -- places the code
is flat where the design comp used a gradient. These would require **new code** (not
just token changes) to implement. The functional spec deliberately chose to keep the
code's flat approach and port only the dark color value.

---

## Manual capture and review script

Automated screenshots were not feasible for this menu-bar app. The app has
transient surfaces (recording requires active mic capture, onboarding requires
state reset, popovers close on focus loss), and toggling system appearance
programmatically during capture would not cover the stateful surfaces. The
reviewer should walk the surfaces manually.

### Setup

1. Build and run: `make build-app` then launch from
   `App/DerivedData/.../Build/Products/Debug/Biscotti.app`, or run from Xcode.
2. Open **System Settings > Appearance**. Keep it visible for quick toggling.
3. Have a past meeting in the database (or use preview/debug data if available).

### Walk-through (do each in Light, then repeat in Dark)

Toggle appearance between each full pass. Confirm live-switch updates without
relaunch.

**Pass 1 -- Light (baseline confirmation):**

1. **Home:** Scroll through greeting, stat chips, upcoming section, past section.
   Confirm it looks identical to pre-dark-mode.
2. **Meeting Detail -- Transcript tab:** Open a meeting with a transcript. Check
   speaker names, timestamps, utterance body text, audio transport bar.
3. **Meeting Detail -- Notes tab:** Check the MarkdownEditor with content. Type
   something. Check placeholder text when empty.
4. **Meeting Detail -- Summary tab:** If a summary exists, check heading + body.
5. **Settings:** Open settings. Check all sections: General, Permissions,
   Notifications, AI Enhancements, Calendars. Note toggles, pickers, buttons,
   warning badges.
6. **Onboarding:** Debug > Replay Onboarding. Walk through Welcome, Permissions
   (with Grant buttons), Model Download (idle, downloading if possible), Done.
   Note the progress bar, CTA buttons, permission cards.
7. **Recording (if safe):** Start a recording (or use preview). Check RECORDING
   badge, Stop & Save button, time chips (Elapsed + Left/Over if applicable),
   note composer, title field.

**Pass 2 -- Dark (the review):**

Repeat steps 1-7 in dark appearance. For each surface, consult the
surface-specific "what to check" items above. Pay special attention to:

- Text legibility (especially `read` in transcripts, `signalRedText` in recording).
- Card elevation (`cardFill` vs `paper`).
- Button fills (`accentFill` with white labels, `elevatedFill` with red content).
- Amber chips (unified `warningChipText`, chip fill visibility).
- Progress bars (`accentTrack` on `hairline` track).
- Shadows (likely invisible on dark -- is that OK?).
- Native controls (toggles, pickers, sliders, menus).

**Pass 3 -- Live toggle:**

With each surface open, toggle Light <-> Dark in System Settings without closing
or navigating away. Confirm:

- Colors update instantly (no stale light colors lingering).
- MarkdownEditor (AppKit NSTextView) updates its text colors live.
- No flash of wrong colors during transition.

### Recording the review

For each surface, note:
- **Pass** -- the dark rendering is acceptable.
- **Tweak** -- acceptable with a specific token value adjustment (note the token
  and suggested direction, e.g. "bump `accentTrack` brighter" or "drop
  `signalRedText`, use `signalRed` for all red text").
- **Reject** -- a structural change is needed (e.g. "add card gradient").

Every tweak must keep light byte-identical (Phase 1 Test 1 re-runs green).
