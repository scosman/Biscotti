---
status: complete
---

# UI Design: LLM Model Selection

Two surfaces: (1) the **always-visible row** in Settings → AI Enhancements, and (2) the new
**Manage Models sheet**. Both reuse existing design-system patterns — no new visual language.

Design-system anchors (from `DesignSystem.Tokens` / existing views):
- Secondary/grey text: `.font(Tokens.metadataFont).foregroundStyle(Tokens.secondaryText)` (same as
  granted-permission text and all subtitles).
- Small actions: `Button(…).buttonStyle(.bordered).controlSize(.small)`.
- Capsule chip (for badges/warnings): the `requiresCalendarAccessBadge` pattern — a `Capsule`
  fill + caption text + optional SF Symbol.
- Warning accent: `.warningOchre` / `Tokens.warningChipFill` + `Tokens.warningChipText`.
- Positive accent: `.sage`.
- Sheet: `.sheet(isPresented:)`, fixed width, `Tokens.spacing*` padding, `@Environment(\.dismiss)`
  (same as `AlertsHelpSheet`).

---

## 1. Settings Row — "AI Language Model"

Lives in the **AI Enhancements** section, directly under the "AI Analysis & Summary" toggle +
description. It is **always shown** (replaces the conditional `modelDownloadRow`). Same horizontal
shape as the permission rows: label/subtitle on the left, trailing status + action on the right.

**State A — an active model exists** (downloaded + selected):

```
┌─ AI Enhancements ───────────────────────  AI runs locally on your Mac. ─┐
│  ◉ AI Analysis & Summary                                            [on] │
│    Generate a title and summary from the transcript, and guess …         │
│                                                                          │
│  AI Language Model                              Gemma 4 12B   [ Manage ] │
│  The AI model used to summarize meetings                                 │
└──────────────────────────────────────────────────────────────────────── ┘
```

- `Gemma 4 12B` = active model's display name in **grey/secondary** text (the granted-permission
  treatment).
- `Manage` = `.bordered`, `.controlSize(.small)` → opens the Manage Models sheet.

**State B — no model downloaded:**

```
│  AI Language Model                                          [ Download… ] │
│  The AI model used to summarize meetings                                 │
```

- No grey model name. A single `Download…` button (`.bordered`, `.small`) opens the sheet (the sheet
  is where the actual download happens).
- The "AI Analysis & Summary" toggle remains **disabled** in this state (unchanged behavior).

**(Optional, low priority) State C — downloading, none active yet:** the trailing area may read
`Downloading… 62%` in grey with the `Manage` button beside it. Acceptable to ship A/B only and let
the sheet own progress.

---

## 2. Manage Models Sheet

Presented from the row's `Manage`/`Download…` button. Fixed-width sheet (~**480 pt**), vertically
sized to content, scrollable if the catalog grows. Built as a **list of model rows** so adding a
catalog entry just adds a row.

```
┌──────────────────────────────────────────────────────────────┐
│  AI Language Model                                            │
│  Choose the model used to summarize your meetings. It runs    │
│  entirely on your Mac.                                        │
│                                                              │
│  ┌────────────────────────────────────────────────────────┐ │
│  │ Gemma 4 12B   ⬤ Recommended                 ✓ Default   │ │
│  │ Intelligent, but slower and larger.          [ Delete ] │ │
│  │ Requires 7 GB of disk and uses 8 GB RAM.                │ │
│  └────────────────────────────────────────────────────────┘ │
│  ┌────────────────────────────────────────────────────────┐ │
│  │ Gemma 4 E2B                              [ Choose Model ]│ │
│  │ Small and fast, but not as intelligent.      [ Delete ] │ │
│  │ Requires 3 GB of disk and uses 4 GB of RAM.             │ │
│  └────────────────────────────────────────────────────────┘ │
│                                                              │
│                                                    [ Done ]  │
└──────────────────────────────────────────────────────────────┘
```

- **Header:** title "AI Language Model" + one-line grey subtitle ("…runs entirely on your Mac.").
- **Footer:** a single `Done` button (trailing) dismisses; dismiss never cancels an in-flight
  download.
- **Rows** are lightly separated cards (a subtle divider or grouped-form styling; match the app's
  grouped `Form` look used elsewhere in Settings).

### 2.1 Row anatomy

```
┌────────────────────────────────────────────────────────────┐
│ <Model name>  <Recommended badge?>      <selection control> │  ← line 1
│ <Description line 1>                     <primary action>   │  ← line 2
│ <Description line 2 / warning / progress>                   │  ← line 3
└────────────────────────────────────────────────────────────┘
```

- **Left column:** name (primary weight) + optional **Recommended** badge on line 1; the two-line
  description in grey below; **warning** or **progress** replaces/*follows* the description when
  relevant.
- **Right column:** the **selection control** (top) and the **primary file action** (below),
  trailing-aligned. When a state has only one control, it sits alone.

### 2.2 Badges & indicators

- **Recommended badge:** a small `Capsule` chip with a **positive/sage** fill and "Recommended"
  caption (mirrors the `requiresCalendarAccessBadge` construction, sage instead of ochre). Exactly
  one row ever shows it.
- **Default (selected) indicator:** a `checkmark.circle.fill` in `.sage` + "Default" text
  (secondary). Clear, non-buttony — it communicates "this is the one in use."
- **Choose Model:** `.bordered`, `.small` button (shown only when downloaded + runnable + not
  selected).
- **Delete:** `.bordered`, `.small`; placed below the selection control. (Could use a subtle
  destructive tint, e.g. red text, but standard bordered is fine.)
- **Download:** `.bordered`, `.small`.

### 2.3 Per-state row mockups

**Runnable · not downloaded · enough disk** (E2B recommended example):

```
│ Gemma 4 E2B   ⬤ Recommended                     [ Download ] │
│ Small and fast, but not as intelligent.                      │
│ Requires 3 GB of disk and uses 4 GB of RAM.                  │
```

**Downloading** (determinate; indeterminate spinner when no Content-Length):

```
│ Gemma 4 12B                                                  │
│ Intelligent, but slower and larger.                          │
│ ▓▓▓▓▓▓▓▓░░░░░░  Downloading… 62%                              │
```

**Download failed:**

```
│ Gemma 4 12B                                                  │
│ Intelligent, but slower and larger.                          │
│ Download failed: <reason>                          [ Retry ] │
```

**Downloaded · selected (Default):**

```
│ Gemma 4 12B   ⬤ Recommended                       ✓ Default  │
│ Intelligent, but slower and larger.                [ Delete ]│
│ Requires 7 GB of disk and uses 8 GB RAM.                     │
```

**Downloaded · not selected:**

```
│ Gemma 4 E2B                                  [ Choose Model ]│
│ Small and fast, but not as intelligent.            [ Delete ]│
│ Requires 3 GB of disk and uses 4 GB of RAM.                  │
```

**Not runnable** (12B on < 15 GB Mac) — whole row greyed/disabled; warning chip replaces actions:

```
│ Gemma 4 12B                                       (disabled) │
│ Intelligent, but slower and larger.                          │
│ ⚠ This Mac can't run this model                              │
```

**Runnable · not downloaded · insufficient disk** — Download disabled, warning shown:

```
│ Gemma 4 12B   ⬤ Recommended                  [ Download ](off)│
│ Intelligent, but slower and larger.                          │
│ ⚠ Insufficient free space on disk                            │
```

- Warnings (`⚠ …`) render in the warning accent (`.warningOchre` text or the warning chip),
  occupying the description's third line so row height stays stable.

### 2.4 Concurrency affordance

While one model downloads, other not-downloaded rows show their `Download` button **disabled**
(greyed) — no extra explanatory text needed; the in-flight row's progress makes the reason obvious.

---

## 3. Delete Confirmation

A standard macOS confirmation (`.confirmationDialog` or `.alert`) before destroying a multi-GB file:

```
Delete Gemma 4 12B?
This frees about 7 GB. You can download it again anytime.
                                          [ Cancel ]  [ Delete ]
```

- `Delete` is destructive-styled; `Cancel` is default.
- On confirm, the file is removed and selection recomputes (functional spec §4.3).

---

## 4. UX Rationale

- **Discoverability:** the model row is now permanent, so the choice is always visible — not hidden
  until a download state. The `Manage` button is the obvious entry point.
- **Progressive disclosure:** the Settings row stays minimal (name + Manage); all complexity
  (sizes, recommendation, download/delete, blocked states) lives in the sheet, surfaced only when
  the user opts in.
- **Low cognitive load / guidance without forcing:** the single **Recommended** badge nudges the
  right choice; blocked models are visibly explained ("This Mac can't run this model") rather than
  silently missing, so the user understands *why*.
- **Platform conventions:** grouped `Form` rows, bordered small buttons, a standard sheet, and a
  destructive confirmation — all already used elsewhere in the app; nothing novel to learn.

---

## 5. Accessibility & Copy

- All buttons have clear text labels; the Recommended badge and Default indicator pair an icon with
  text (never icon-only).
- Warning text is real text (not color-only), so meaning survives without color perception.
- Exact copy strings (single source — match the functional spec catalog):
  - Row title/subtitle: "AI Language Model" / "The AI model used to summarize meetings".
  - Sheet subtitle: "Choose the model used to summarize your meetings. It runs entirely on your Mac."
  - Warnings: "This Mac can't run this model" / "Insufficient free space on disk".
  - Descriptions: per-model copy from the catalog (functional spec §2).
