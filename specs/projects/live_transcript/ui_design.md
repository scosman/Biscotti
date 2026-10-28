---
status: complete
---

# UI Design: Live Transcript

Visual and interaction design for the behavior in [functional_spec.md](functional_spec.md). The design was drawn up from image-model edits of real screens, which are not kept in the repo: they showed layout and intent, and the design tokens below win wherever sizes, colors or fonts differ.

## Surfaces

| Surface | Where |
|---|---|
| Live toggle, collapsed | Recording screen, bottom left of the drawer's area |
| Live drawer, expanded | Recording screen, floating over the bottom of the window, below the notes |
| Transcript view | The drawer body and every meeting's Transcript tab |
| Menu command | View > Show / Hide Live Transcript (⌘T) |
| Settings row | Settings → General |

## Tokens

All colors are the existing dynamic tokens, so light and dark mode come for free.

| Role | Token |
|---|---|
| Window background | `Color.paper` |
| Drawer card and collapsed button | `Tokens.cardFill`, stroke `Tokens.cardStroke`, shadow `Tokens.cardShadow` |
| "Others" bubble fill | `Tokens.neutralChip` |
| "You" bubble fill | `Tokens.softSageFill` |
| Settled text | `Color.ink` |
| Unsettled tail | `Color.inkSecondary`, which must meet 4.5:1 on both bubble fills |
| Typing dots | `Color.inkTertiary` |
| Speaker name | `Tokens.avatarPalette[avatarColorIndex(forKey:)]`, the existing per-speaker color; "You" uses `Color.sage` |
| Times, kicker, status text | `Color.inkTertiary` / `Color.inkSecondary` |
| Waveform bars, live | `Color.sage`; unavailable: `Color.inkTertiary` |
| Search matches | Current: `Color.findHighlightFocused`; others: `Tokens.accentWashStrong` |
| Hairlines | `Tokens.hairline` |

New tokens: `Tokens.bubbleRadius = 14` and `Tokens.drawerRadius = 16`. The drawer is a floating panel, so it uses a softer corner than the 12 pt `cardRadius` used for inline cards.

## Typography

| Role | Font |
|---|---|
| Bubble text | System 14, regular |
| Speaker name | System 12, semibold |
| Time beside the name | `Font.biscottiMono(12)` |
| `TRANSCRIPT` kicker | `Font.monoKicker` (10.5, medium, tracked) |
| Status beside the toggle | `Font.monoMeta` (12.5) |
| Gap marker, draft label | `Font.monoCaption` (10) uppercase, tracked |
| "Return to live" | System 12, medium |

## Layout metrics

| Element | Metric |
|---|---|
| Collapsed toggle | 44 × 44 pt circle. Leading edge 12 pt inside the drawer's leading edge, where the open drawer's footer holds it; 16 pt (`spacingMD`) above the window's bottom edge. |
| Expanded drawer | The window's width less 16 pt on each side, at most 880 pt, centered: wider than the 600 pt notes column, so bubbles are wide and short. Height 45% of the detail area, at least 240 pt and at most 520 pt. Bottom edge 16 pt above the window's bottom. |
| Drawer header and footer | 44 pt tall each, 16 pt side padding, hairline separators. |
| Bubble | Padding 8 pt vertical, 12 pt horizontal. At most 75% of the content width. |
| Bubble spacing | 4 pt between bubbles in one speaker's run, 12 pt between runs, 4 pt from a run's label to its first bubble. |
| Notes scroll inset | The notes list gets a bottom content inset of the drawer's height plus 16 pt when expanded, and 60 pt when collapsed, so the last note is never hidden. |
| Notes when the drawer opens | The notes scroll up so the note field's bottom sits 16 pt above the drawer; the header scrolls up with them, but the column's top (the status row with Stop & Save, or the auto-stop card above it) stays at least 16 pt below the window's top. To fit all three, the drawer first shrinks, to no less than 240 pt; in a window too short even then, the drawer covers the note field. Closing the drawer scrolls the notes back. Both move with the drawer's spring. |

## Recording screen

### Collapsed

```
│  0:50   Confirm the crash fix is in Monday's beta.          │
│                                                             │
│                                                             │
│  ( ▮▮▮ ⌃ )                                                  │  ← 44 pt circle, where the open drawer's footer holds it
└─────────────────────────────────────────────────────────────┘
```

- The circle holds the waveform (four 3 pt wide rounded bars, 6 to 16 pt tall) and a 9 pt "chevron.up".
- Tooltip: "Show transcript (⌘T)". Hover fills the circle with `Tokens.neutralChip`; pressed darkens it by a further 6%.
- No transcript text appears while collapsed.

### Expanded

```
┌─────────────────────────────────────────────────────────────┐
│ ⌕  TRANSCRIPT                                          ⧉  − │  ← header, 44 pt
├─────────────────────────────────────────────────────────────┤
│ Okay, so the beta build goes out to the first fifty…        │
│                       Do we have the crash fix from Friday… │
│ ─────────── NOT TRANSCRIBED LIVE · 0:12 ───────────         │
│ Yes, Priya merged it this morning. QA signed off an hour…   │
│              Great. Then let's keep the pricing page hidden…│
│ That works, and I'll send the release notes draft tonight ••│
│                      ( ↓ Return to live )                   │  ← only when scrolled up
├─────────────────────────────────────────────────────────────┤
│ ▮▮▮ ⌄  Catching up                               文A English ⌄ │  ← footer, 44 pt
└─────────────────────────────────────────────────────────────┘
```

- The card grows upward from the toggle. The toggle stays at the same screen position, now at the footer's leading edge with a "chevron.down" and the tooltip "Hide transcript (⌘T)".
- The card spans most of the window's width, wider than the notes column. The notes move up with it, so the note field stays in view just above the card and typing goes on.
- Header: a "magnifyingglass" button, the `TRANSCRIPT` kicker, and on the right a "doc.on.doc" copy button and a "minus" collapse button ("Hide transcript (⌘T)", added in the hardware review). Copy shows a checkmark for 1.5 s after copying, like the Transcript tab's Copy.
- Footer: the toggle and its status text on the left; the language menu on the right (a "character.bubble" glyph, the current language, and a chevron).
- The drawer bubbles carry no name labels: in a recording there are only two sides, and position and color show them.

### Toggle states

| State | Waveform | Status text, expanded only |
|---|---|---|
| Starting | A small `ProgressView` in place of the bars | "Starting" |
| Live | Sage bars animating with the audio level, about 12 updates per second | None |
| Catching up | Sage bars | "Catching up" |
| Paused | Still sage bars at 50% opacity | "Paused while the Mac cools down" |
| Unavailable | Still `inkTertiary` bars | The reason, for example "Needs the transcription model" |

The bars follow the combined mic and system level. With Reduce Motion on, they hold a steady mid height while live.

### Search

Clicking the magnifying glass turns the header into a find bar: a field ("Find in transcript"), a "2 of 5" count, previous and next buttons ("chevron.up", "chevron.down"), and a close button. Matches highlight in every bubble, the current one more strongly. Return and Shift-Return move between matches. The first Esc closes the find bar; a second Esc hides the drawer. Following stops while the find bar is open and resumes when it closes, if the view is at the bottom.

### Language menu

A standard menu with two items, each a title and a gray subtitle:

- "English" / "Best quality"
- "Detect language" / "Finds the language once, then keeps it"

The current choice has a checkmark. After Detect language identifies the language, the footer shows it, for example "French". With SpeechAnalyzer, the menu lists that engine's supported languages instead.

### Following, gaps and the tail

- **Return to live:** a capsule centered above the footer, `Tokens.elevatedFill` with `Tokens.controlShadow`, "arrow.down" plus "Return to live". It fades in when following stops and out when it resumes. While following is off, the drawer holds its items still; Return to live applies everything that arrived meanwhile.
- **Gap marker:** a centered `NOT TRANSCRIBED LIVE · 0:12` caption between hairlines, spanning the content width, with the tooltip "Recording continued. The saved transcript includes this part." Touching gaps, of either side, form one stretch. It shows, at its full length, only when the parts not known to be silent total 5 s or more: a stretch whose dropped audio was all silence shows nothing, and so does a shorter one. The drawer and the Transcript tab's draft follow the same rule; the gaps stay in the live transcript and its snapshots.
- **Start marker:** when live transcription starts mid-recording, the first row is a centered caption, `LIVE TRANSCRIPT STARTED AT 4:12`.
- **Typing dots:** three 4 pt circles after the tail, pulsing in turn (0.9 s cycle). With Reduce Motion on, they stay still.

### Motion

Expanding and collapsing use a 0.25 s spring that scales and fades the card from the toggle's position. With Reduce Motion on, the card cross-fades in 0.15 s. New bubbles appear without animation.

## Transcript tab

The tab keeps its header, segmented tabs, version picker, Copy button and audio player. Only the area below the tab row changes, to the same bubble view as the drawer.

```
Priya · 0:31                                          ← name in speaker color, time links to seek
( Okay, so the beta build goes out to the first fifty customers on Monday. )
                                                         You · 0:38
                       ( Do we have the crash fix from Friday in that build? )
Marcus · 0:42 ▶                                       ← play button on hover
( Yes, Priya merged it this morning. QA signed off an hour ago. )
```

- **Run labels:** each run of one speaker's bubbles has a label: the speaker's name, then the start time. Others' labels are left-aligned; yours are right-aligned, with "You" in `Color.sage`.
- **Name:** clicking it opens the speaker-mapping sheet, as today.
- **Time:** clicking it seeks the audio player, as today's `biscotti://seek` link does. Hovering a bubble also shows a "play.fill" button after its run's label, which plays from that bubble. Without audio, names and times are plain text.
- **Who sits on the right:** a speaker tagged as you (see the functional spec). Untagged speakers, and everyone in meetings where you were never tagged, sit on the left.
- **Draft after Stop:** a `StatusRow` above the bubbles reads "Draft · final transcript in progress", with a small spinner. It shows "You" and "Others" labels from the live transcript.
- **Waiting:** an earlier meeting held back by a recording shows a `StatusRow` with "Waiting to finish until the current recording stops".
- **Other states:** processing, failed, "No transcript yet" and "Transcription empty" stay as they are today.
- **Width:** the bubble column uses today's readable width; bubbles reach at most 75% of it.

## Recording notes

A note's time ("0:50") becomes a link styled like a transcript time. Clicking it opens the drawer at that moment. Hovering it shows the tooltip "Show in transcript".

## Menu and Settings

- **View menu:** "Show Live Transcript", which reads "Hide Live Transcript" while open, with ⌘T. It is placed after the sidebar item and disabled when nothing is recording or live transcription is off.
- **Settings → General:** a toggle, "Show live transcript while recording", placed after "Stop Recording Automatically". It has no caption, except while models load in the background after an install, an update or a model download: then, while the live model is the one loading, a mini spinner and "Preparing live transcript…" show under it in the caption style (`Tokens.metadataFont`, `Tokens.secondaryText`).

## Accessibility

- The toggle's VoiceOver label is "Show transcript" or "Hide transcript", and its value is the state ("Live", "Starting", "Catching up", "Paused", "Unavailable").
- Each bubble is one element, read as "You: …" or "Priya, 0:31: …". The draft label and gap markers are read as written.
- Settled text is read. Tail changes post no announcements, and the drawer posts none while it is hidden.
- With Differentiate Without Color on, the tail also gets a dotted underline, and sides still show the speaker.
- Keyboard: Tab moves into the drawer after the notes field. Arrow keys and Page Up/Down scroll it. ⌘T and Esc hide it.
- Text in every bubble, including the unsettled tail, meets 4.5:1 contrast against its fill in light and dark mode. A unit test checks each text token against each bubble fill in both appearances.

## Reused and new pieces

Reused: `StatusRow`, `Banner`, `VersionPicker`, the Copy button, `Tokens.avatarPalette` with `avatarColorIndex(forKey:)`, `SpeakerMappingSheet`, the audio transport's seek, `Tokens` spacing.

New: the transcript bubble view (shared by drawer and tab), the run label, the live toggle with its level meter, typing dots, the Return to live capsule, gap and start markers, the drawer card, and the drawer find bar.

## Open decisions

1. **Drawer height:** fixed at 45% of the detail area (between 240 and 520 pt), as above. Making it resizable by dragging the top edge is easy to add later; it is left out to keep the first version simple.
2. **Corner radius:** the mockups showed rounder corners than the app's 12 pt cards. This design adds a 16 pt drawer radius and a 14 pt bubble radius rather than reusing 12 pt.

## Changes from UI review (25 October 2026)

After recording a real meeting with a test build, the user chose these changes. They replace the earlier rules above where the two differ.

1. **Wider drawer, notes move.** The drawer spans most of the window's width, up to 880 pt, so bubbles are wider and shorter; they keep the 75% rule. Opening it moves the notes up so the note field sits just above it, and the header scrolls up with them, though never so far that Stop & Save, or the auto-stop card, leaves the window. This reverses the earlier rule that the header and the note field never move. The collapsed toggle sits where the open drawer's footer holds it, so it still does not jump.
2. **Quieter gap markers.** "Not transcribed live · 0:12" with the tooltip "Recording continued. The saved transcript includes this part.", shown only for a stretch in which 5 s or more may have held sound.
3. **Bubbles in conversation order.** A live bubble also ends when the other side starts speaking, at a sentence end once it is about 8 s long, and at a word once it reaches about 20 s, so the two sides interleave like a chat ([live_session](components/live_session.md#the-agreement-reducer)).
4. **Prepared in the background.** The first live start after an update waited almost two minutes while macOS compiled the model. Biscotti now loads the models once in the background after an install, an update or a model download, while nothing records; Settings shows "Preparing live transcript…" meanwhile ([transcriber_worker](components/transcriber_worker.md#model-preparation)).

## Changes from the second UI review (25 October 2026)

After the round 1 build, the user chose these changes. They replace the rules above where the two differ.

1. **Height handle.** The drawer keeps its width (at most 880 pt). Its top edge drags to change the height, with the vertical-resize pointer and a small grabber that shows on hover. The height stays between 240 pt and the height that keeps the status row with Stop & Save (and the auto-stop card) in view; a tall drawer may cover the note field. The notes follow the height: the note field sits 16 pt above the drawer when it can. The height is remembered across meetings. Double-click on the edge restores the default height, which fits the window as before. VoiceOver adjusts the height in 40 pt steps and has a "Restore default height" action. This settles open decision 1.
2. **Backfill.** The live transcript covers the recording from its start: audio recorded before the engine runs, and during restarts, is kept (up to 15 minutes per track) and transcribed in a catch-up mode, then the drawer streams at the live edge. While the live text is behind, the header shows "Catching up…" with a mini spinner next to the `TRANSCRIPT` kicker; the footer no longer repeats it. The drawer still follows new rows. "Not transcribed live" markers now appear only for audio beyond the 15-minute backlog, capture gaps and a finish that ran out of time, with the round 1 rules.
3. **Fast starts.** The live model stays loaded in the transcription worker while the live transcript is on, so a live start takes seconds ([transcriber_worker](components/transcriber_worker.md#keeping-the-live-model-loaded)). It stays loaded during final transcriptions too (chosen by the user on 25 October 2026).
4. **Low disk space** (chosen by the user on 25 October 2026). A slow load is explained where it shows:
   - **Drawer:** after 10 s of Starting, the placeholder reads, on a low disk, "Your Mac is low on disk space, so macOS removed the prepared speech model." / "Preparing it again takes about 2 minutes. The transcript will catch up from the start."; otherwise "Preparing the speech model." / "The first time takes a couple of minutes. The transcript will catch up from the start." Same two-line caption style as before, which they replace.
   - **Final transcription:** "Transcribing…" gets the subtitle "Taking longer: your Mac is low on disk space" while its model load runs past 15 s on a low disk; a shown draft's "Draft · final transcript in progress" gets the same subtitle.
   - **Settings:** under the live transcript toggle, a row with the ochre warning triangle and the caption "Your Mac is low on disk space, so macOS may remove the prepared speech models and transcription can start slowly. Free up space to avoid this."

## Changes from the hardware review (25 October 2026)

The user chose these during the phase 11 hardware review. They replace the rules above where the two differ.

1. **Collapse button in the header.** Asked for by the user in the hardware review, after Granola's transcript panel: a "minus" button at the header's trailing edge, after Copy, in the same 13 pt icon style, hides the drawer ("Hide transcript (⌘T)"). The footer toggle, ⌘T and Esc still hide it too. The mockups showed the header without it.
2. **Device-switch marker.** A gap stretch made only of capture gaps, where the microphone or speakers were switching and nothing was recorded, reads "Audio paused while switching devices · 0:07" with the tooltip "Your microphone or speakers were switching; nothing was recorded here." "Not transcribed live" and its tooltip stay for audio that was recorded but missed by the live transcript. A stretch with both keeps "Not transcribed live", because the saved transcript has part of it. Chosen by the user on 25 October 2026.
3. **Find returns to live.** Closing the find bar returns to live when the drawer was following when find opened; a reader who was reading back stays where they are.
