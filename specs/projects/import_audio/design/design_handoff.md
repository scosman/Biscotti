# Handoff: Import Audio (Biscotti, macOS)

## Overview
Lets users import existing audio or video files into Biscotti. There are two ways to start an import: **File > Import Audio File…**, or dropping files anywhere on the app window. A new **Import** screen in the main area converts each file to Biscotti's standard audio format. After conversion, each file goes through the normal post-recording flow (transcribe, summarize, LLM naming), which is reused unchanged.

## Product brief (verbatim from product owner)
```
I want an option to import audio files into biscotti.

UX:
2 ways to initiate
File > Import Audio File option that opens a file picker
Whole window is a drag and drop target. When you drag a file over it shows the "drop state" (design coming shortly)
Importing Screen: after initiating, you end up on the importing screen, a new screen in main area. Pretty simple: just a spinner and status message while it converts the audio file into our standard format. On complete it jumps to meeting view, and you get the usual post-recording UX (transcribing, etc) -- all of that is reused. If re-encode fails the import screen shows and error.
Use the default meeting name you get from record button, and let the LLM given name replace it (already does that, just don't break it).
Invalid files dragged over:
single: the overlay shows "Can't import this file", and modify colors
multi and mix of some are okay and, others not: title still says "Drop to import N files"  with error message below "N files are unsupported file types and will be skipped."

Technical:
multi-file drop works.
The drag and drop and import screen both support it.
The "Drop to import" just becomes "Drop to import N files" for multi.
The import screen shows a list and it processes in order. Next to each: spinner at first, then "Go to Meeting" when encode done ( instead of automatically jumping to meeting which we do for single fil).
File formats: allow all the standard audio file extensions (wav, mp3, mp4, M4A, caf, etc
video files are okay: extract audio track only
Re-encode: use the standard MacOS audio stack to re-encode.
```

Design decisions made after the brief (approved):
- The Import screen is **one view, a file list**, for both single and multi-file imports. A single import is a list with one row.
- A single-file failure appears as an error row in that list. There is no separate error screen.
- If **all** dropped files are unsupported, show the single-file "Can't import this file" state.

## About the design files
`Import Audio.html` is a **design reference built in HTML**, not production code. Recreate it in the Biscotti macOS app (SwiftUI) using the app's existing components, tokens and patterns. Open it in a browser to view it as a pannable canvas. The window chrome and Home content in the mocks are simplified stand-ins for the real app. Only the overlay and the Import screen are new.

## Fidelity
**High fidelity** for the drop overlay and the Import screen: colors, type, spacing and copy are final. Use the existing Biscotti tokens (sage `#4E7D5C`, ink `#1A1813`, paper `#FBFAF5`, Deep Ink dark mode) where they already exist in code.

---

## Screen 1: Drop overlay

**Trigger:** a drag carrying file URLs enters the window, anywhere (sidebar, toolbar, main area, any screen). Register the drop target on the root window content so no child view swallows it. The overlay is removed on drag exit, on drop, or on Esc.

**Layout**
- Covers the **entire window content**, above everything, sidebar included. It clips to the window's 13px corner radius.
- Veil: paper color at 76% opacity (`rgba(251,250,245,.76)`; dark `rgba(16,14,9,.74)`) with a background blur of about 7px. In SwiftUI, use `.ultraThinMaterial` or a `.background` blur tinted with paper.
- Drop zone: inset **12px** from all window edges, corner radius **9px**, **2px dashed** border in sage at 70% opacity, fill sage at 5% opacity.
- Content is a centered vertical stack with a 14px gap:
  - Tile: 76×76, radius 20, sage button gradient `#5D9069 → #43704F`, inset top highlight `rgba(255,255,255,.22)`, shadow `0 10px 24px rgba(40,70,45,.22)`. It holds a white 5-bar waveform glyph (bars 4px wide, 4px gap, radius 2, heights 14/28/40/22/32). Use an SF Symbol (`waveform`) if preferred. 6px extra space below the tile.
  - Title: Newsreader 500, 34px, line-height 1.1, tracking −0.01em, ink.
  - Subtitle: system 15px, line-height 1.45, ink 54%, max-width 440.
  - Format line: IBM Plex Mono 11.5px, tracking 0.06em, ink 34%.

**States and copy**
| State | Title | Below title | Zone colors |
|---|---|---|---|
| 1 supported file | Drop to import | "Biscotti will transcribe and summarize it on your Mac." + format line | sage |
| N supported files (N>1) | Drop to import N files | "Each file becomes its own meeting." | sage |
| Mixed (some unsupported) | Drop to import N files (N = supported count) | "Each file becomes its own meeting." + skip notice (below) | sage |
| All unsupported (1 or more) | Can't import this file | "Biscotti imports audio and video recordings." + format line | neutral |

- Skip notice (mixed state): a pill 30px tall, radius 8, padding 0 12px, fill ink 5.5%, 13px text in ink 54%, with a 16px circled "!" icon in ink 34%. Copy: "**M** files are unsupported file types and will be skipped." Use the singular for M = 1: "1 file is an unsupported file type and will be skipped."
- Neutral (unsupported) state: dashed border in ink 34%, no fill. The tile has fill ink 5.5%, no shadow, and the glyph in ink 34%. Return `.forbidden` / reject the drop so macOS shows no "+" badge on the drag image.
- Format line copy: `WAV · MP3 · M4A · AAC · AIFF · CAF · FLAC · MP4 · MOV`. This is a display list. The real check is by UTType (see Technical).

**Motion:** fade the overlay in and out over 120–150ms, ease-out. No scale or bounce.

## Screen 2: Import (main area)

Replaces the main column content. The sidebar stays. The toolbar title is **Import**; search and the Record button remain.

**Layout:** a top-aligned centered column, 72px from the toolbar, 64px side padding.
- Title: Newsreader 500, 30px, tracking −0.01em.
  - In progress: "Importing N file(s)" (singular "Importing 1 file").
  - Complete: "Imported X of N files" (if every file succeeded: "Imported N files").
- Status line below the title, 12px gap:
  - In progress: IBM Plex Mono 13px, ink 54%, "i of N · converting audio" (single: "converting audio").
  - Complete: system 15px, ink 54%, "Transcripts and summaries are being written in each meeting."
- List card: max-width 620, top margin 14, white card (dark `#1A170F`), 0.5px border ink 11%, radius 12. Rows are 60px tall with 16px horizontal padding and 0.5px separators.

**Row anatomy:** 32×32 icon tile (radius 8) → name + meta → trailing status.
- Name: system 14px, weight 500, single line, truncate with an ellipsis.
- Meta: IBM Plex Mono 12px, ink 54%: source duration `mm:ss` or `h:mm:ss`.

| Row state | Icon tile | Meta | Trailing |
|---|---|---|---|
| Waiting | fill ink 5.5%, waveform ink 34% | duration | "Waiting", Plex Mono 13px, ink 34% |
| Converting | fill sage 12%, waveform sage | duration | 16px spinner (2px stroke, sage on sage 20% track) + "Converting…" 13px ink 54% |
| Done | fill sage 12%, waveform sage | duration | **Go to Meeting** bezel button (28px tall, white, radius 8, 0.5px ink 16% ring, 13px/500) |
| Failed | fill red 11%, red "!" | "Couldn't convert this file. It may be damaged." in system 12px, red text `#B23320` | **Show in Finder** bezel button |

**Single-file behavior:** when the only file finishes converting, navigate straight to its meeting view (no Go to Meeting step). If it fails, stay on the Import screen and show the failed row.

**Multi-file behavior:** convert files sequentially, in drop or picker order. Do not auto-navigate. Each finished row gets Go to Meeting. The meeting is created as soon as its conversion finishes, so transcription can start while the next file converts.

Leaving the Import screen mid-import is not designed. The recommendation is to let conversion continue in the background. Confirm this during spec.

## Interactions & behavior
- **File > Import Audio File…** (suggested shortcut ⌘⇧I, to be confirmed): opens an `NSOpenPanel` that allows multiple selection, filtered to audio and movie types. Confirming opens the Import screen.
- **Drop:** opens the Import screen with the supported files only. Unsupported files are silently skipped; the overlay already warned about them. If every file is unsupported, the drop is rejected and nothing happens.
- **Meeting name:** use the same default name the Record button produces. The existing LLM rename must still replace it.
- **After conversion:** hand off to the existing post-recording pipeline (transcribe, summarize). Do not fork it.

## Technical notes
- Supported types: anything conforming to `UTType.audio` or `UTType.audiovisualContent` / `.movie` that contains an audio track. That covers wav, mp3, m4a, aac, aiff, caf, flac, mp4, mov, etc. While the drag hovers, classify each file by its UTType (from the file extension), which is cheap. Check for an audio track when importing; a file with no audio track becomes a failed row.
- Conversion: use AVFoundation (`AVAssetReader`/`AVAssetWriter` or `AVAssetExportSession`; `AVAudioFile` also works for pure audio). Extract the audio track only and write to Biscotti's standard recording format.
- Duration for the row meta: `AVURLAsset.load(.duration)`. Show the row immediately and fill in the duration when it loads.

## State
- `dragState`: `none | supported(count) | mixed(supported, unsupported) | unsupported`
- `importQueue`: an ordered array of `{ url, displayName, duration?, status: waiting | converting | done(meetingID) | failed(error) }`
- Derived: `isSingle = queue.count == 1`, `completed`, `succeeded`

## Design tokens used
- Sage `#4E7D5C` (dark: fill `#56906A`, text `#86C295`); button gradient `#5D9069 → #43704F`
- Ink `#1A1813`; secondary 54%; tertiary 34%; separators 11%; chip fill 5.5%
- Paper `#FBFAF5`; card `#FFFFFF`; dark paper `#100E09`; dark card `#1A170F`; dark ink `#F7F2E8`
- Red `#C9402B` for icons, `#B23320` for text (dark `#E5604A`). Use red only for failed rows.
- Fonts: Newsreader 500 (titles), IBM Plex Mono 400/500 (numbers, durations, the format line), SF Pro (everything else)
- Radii: window 13, drop zone 9, tile 20, card 12, buttons and pills 8, row icon 8

## Files
- `Import Audio.html`: canvas with every state.
  1. Drop, supported (light)
  2. Drop, supported (dark)
  3. Drop, mixed (5 dragged, 3 supported)
  4. Drop, unsupported
  5. Import, single file converting
  6. Import, multiple files in progress (done, failed, converting, waiting)
  7. Import, multiple files complete
