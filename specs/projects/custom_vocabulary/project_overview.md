---
status: complete
---

# Custom Vocabulary

Custom vocabulary is a feature that lets the Biscotti transcriber recognize words it might struggle
with (names, codenames, technical terms).

**Note: this is partly already built.** Do not assume we are starting fresh. This spec takes the
feature to completion from the actual codebase state.

Pull in older information and plans (`specs/app_overview.md` §Custom Vocabularies,
`specs/architecture.md` component 13, `specs/projects/stage_c/**` §4.4 / §10 / Phase 9) when helpful.
Build on it, but this is a standalone spec to implement.

## Backend

Should be done (the `argmax-oss-swift` v1.1.0 bump landed on this branch; see
`specs/research/argmax/README.md` Gotcha #16).

## Custom word list

A user can maintain a list of words in settings. These get applied to every meeting. Personally I'd
add my last name, my company's name, some technical terms, etc. Words I use often, and often fail
transcription.

## Automatic vocabulary from meeting metadata

We automatically generate a per-meeting custom vocab based on the meeting metadata.

- People names (skip if more than 20 invitees, huge meetings don't count). Just first names.
- Company name (from email domain), skip if more than 5 unique domains.
- Uncommon words from event title and description (see below)

### Uncommon words plan

For filtering to uncommon words, we bake a list into the binary. We pass the title and description
through a function to get uncommon words to add.

Something like this for one-time export of word list. No need to encode scores like the example below
does, just a flat cutoff for simplicity: if in list we include, if not we exclude. Set filter as 3.0
for now (human reviewed).

```python
from wordfreq import get_frequency_dict, zipf_frequency
words = get_frequency_dict('en', wordlist='large')
with open('en_zipf.txt', 'w') as f:
    for w in words:
        z = zipf_frequency(w, 'en')
        if z >= 1.5 and w.isalpha():
            f.write(f"{w}\t{z:.2f}\n")
```

Note: need a hit-rate threshold. If meeting text is in another language, we'll get high hit rate and
this will make actively transcription worse. If hit rate > 20% of checked words, drop this method all
together.

If list of uncommon words > 15, drop this method all together. This is a "few outliers" not "other
language" or "flood context".

Do not keep this long list in memory long term. Extra few MS to load, but don't want a 1MB long term
memory hit.

TBD algorithm (build dict vs single pass against list of words in title/description). Lean: build
dict for "words in title/description" then 1 linear pass of words in zipf list. So O(N) (N=dict
size). I assume this is fast, but measure. Don't even need whole zipf word list in memory, can go in
order.

## UI for Re-transcribe after attaching metadata

When I manually attach calendar metadata AFTER a meeting is already transcribed, show an alert
"Re-transcribe with keywords from this event?" / "We'll use this event's title, description and
attendee list to improve transcription accuracy.": "Ok" / "Cancel"

## Settings Screen

New "Custom Vocabulary" section in settings, under general

- "Custom Vocabulary" title
  - subtitle: "Help Biscotti recognize uncommon words you use, like names or technical terms."
  - toggle: if off, other 2 options disappear. If on they appear (and default on)
- "Vocabulary List"
  - subtitle: "Words to watch for in every meeting."
  - button: "Edit List (N)" with current count. Opens modal to add/remove screen
  - Saved to user default I assume is best?
- "Add Words from Calendar Events"
  - subtitle: "Pull uncommon words from the event's title, description, and attendee names. English
    only."
  - Boolean on off toggle, default on.

## Case/Capitals

Keep capitals. Earlier forced lower case, but that's not a goal!

If mixed case: then vocab word should be lower case. If consistent case (always capitalized e.g.
"Notion" as company name), use exact string.
