---
status: complete
---

# Functional Spec: Speaker Embeddings (Voiceprint Database)

Read [`project_overview.md`](project_overview.md) for intent and
[`sdk_findings.md`](sdk_findings.md) for the verified SDK facts. Roadmap entry:
**Project 11 — Auto-Speaker Identification**.

---

## 1. Purpose

Today, one signal identifies speakers: the LLM reads the transcript and the
calendar invite, and selects a name for each speaker. This signal is good, but
it starts from zero in each meeting. If nobody says a name, the LLM has no
evidence.

This project adds a second signal that improves over time. SpeakerKit already
makes a voice description for each speaker in each meeting. We keep these
descriptions, link them to people when names are set, and compare new speakers
against the history.

The two signals work together. The voiceprint matcher runs first and writes a
**report**. The LLM reads the report with the transcript and makes all final
decisions. The matcher never sets a name.

### Goals

1. Save voiceprints for each speaker in each meeting.
2. Get the better voiceprint kind from SpeakerKit (PLDA, §3.5), through a
   SpeakerKit fork and an upstream patch.
3. Compare new speakers against saved voiceprints, with a confidence level.
4. Give the LLM a clear report, so that it can make better name decisions.
5. Tell the LLM which invitee recorded the meeting.
6. Give the developer tools: fill the database from old meetings, measure
   accuracy, and inspect matches in a debug window.

Non-goals are in §12.

---

## 2. Terms

| Term | Meaning |
|---|---|
| **Diarization speaker** | One speaker that SpeakerKit finds in one recording: "Speaker 0", "Speaker 1". The numbers are local to that recording. |
| **Voiceprint** | A list of numbers that describes one diarization speaker's voice. Two recordings of the same voice give voiceprints that point in a similar direction. Also the name of the stored record (§3). |
| **Voiceprint kind** | **Raw** (256 numbers, the embedder output) or **PLDA** (128 numbers, the raw vector after SpeakerKit's PLDA transform). See §3.5. |
| **Distance** | How different two voiceprints are. From 0 (same direction) to 2 (opposite). Cosine distance. |
| **Person** | An existing `Person` row: a name, and an email if known. One human can have more than one `Person` row, for example "Steve" and "steve@kiln.tech". We do not merge them. |
| **Speaker tag** | An existing link on a transcript from a diarization speaker to a person: `Speaker 1 → Steve`. Stored in `TranscriptRecord.speakerAssignments`. |
| **Confirmed tag** | A speaker tag that the user set (`userSet == true`). |
| **Inferred tag** | A speaker tag that the LLM set (`userSet == false`). |
| **Embedding space** | The SpeakerKit models that made a voiceprint (and its kind). Voiceprints from different spaces cannot be compared. |
| **Confidence level** | The matcher's result for one speaker: `high`, `medium`, `low`, `ambiguous`, or `none`. |

---

## 3. Saving voiceprints

### 3.1 What we save

Each time Biscotti transcribes a meeting, we save a **voiceprint record** for
each diarization speaker and each voiceprint kind that SpeakerKit returns. A
speaker normally gets two records: one raw, one PLDA. We always do this: when
the speaker has a name or not, when the LLM runs or not.

A voiceprint record contains:

| Field | Source | Notes |
|---|---|---|
| Vector | SpeakerKit centroid for that speaker and kind | Saved **as SpeakerKit gives it** (not normalized). |
| Kind | Raw or PLDA | |
| Embedding space | SpeakerKit model info | See §3.4. |
| Dimension | Number of values in the vector | Saved so that a mismatch is found, not a crash. |
| Diarization speaker ID | The dictionary key | Used to find the speaker tag. |
| Transcript | The owning `TranscriptRecord` | Deleted with the transcript. |
| Speaking time | Sum of that speaker's diarization time ranges | Used as a weight. See §5.2. |
| Created at | Current time | For reports and debugging. |

We save vectors without normalization, and normalize them in memory when we
compare. Then we keep all of the original data, and we can change the
comparison method later without a rebuild.

### 3.2 A voiceprint record does not store a name

A voiceprint record stores only "Speaker 1 of transcript X". When the matcher
needs the name, it reads the speaker tag on transcript X at that time.

**Why:** assume that you tag Speaker 1 in a meeting from six months ago. That
meeting's voiceprints are now linked to the correct person at once. We do not
update any saved data. If each record stored its own copy of the name, each tag
change would need a data rewrite.

This is how "name it later" works. All tagging can happen later, and old
voiceprints become useful when it does.

### 3.3 SpeakerKit option: `.trainableOnly`

The diarization call changes to
`PyannoteDiarizationOptions(centroidSource: .trainableOnly)`. With this option,
SpeakerKit uses only audio windows where the speaker talks without much overlap
(at least 20% of the window). The voiceprints are cleaner. The option applies
to both kinds.

**Result: some speakers do not get a voiceprint.** This occurs for a speaker who
only talks at the same time as other people. That speaker is still in the
transcript. This is an expected result, not an error:

- No voiceprint record is saved for that speaker.
- The report says that no voiceprint is available for that speaker.
- Nothing is logged as a failure.

All code that reads centroid dictionaries must handle a missing key.

### 3.4 Embedding space

Voiceprints can be compared only when the same SpeakerKit models made them.
SpeakerKit selects some model variants at runtime from the OS version, so a
hardcoded value is not safe. We read the space from SpeakerKit's own model
info:

| Kind | Space key (example) | Source |
|---|---|---|
| Raw | `pyannote-v3/W8A16` | `ModelInfo.embedder()` version / variant |
| PLDA | `pyannote-v3/W8A16+plda:pyannote-v4/W32A32` | embedder, plus `ModelInfo.plda()` version / variant |

If a SpeakerKit update changes a model, the key changes automatically.

**The matcher ignores all voiceprints from a different space.** This is not an
error, and the user sees no warning. The database becomes empty for matching,
and fills again when meetings are transcribed again, or when the developer runs
the backfill tool (§9.1).

We never delete voiceprints because of a space change.

### 3.5 PLDA voiceprints and the SpeakerKit fork

SpeakerKit makes two vector types for each audio window:

- **Raw** (256 numbers): the embedder output. SpeakerKit averages these per
  speaker and exposes the average (`speakerCentroidEmbeddings`).
- **PLDA** (128 numbers): the raw vector after the `PldaProjector` model, which
  centers, rotates, and scales the vector. Its purpose is to separate *who is
  talking* from *how it was recorded* (microphone, room). That is the difficult
  part of matching across recordings. SpeakerKit uses these only inside its own
  clustering. It does not average them or expose them.

This project gets PLDA averages:

1. Fork `argmax-oss-swift` from the `v1.1.0` tag (the version we use).
2. Add a public `speakerPLDACentroidEmbeddings: [Int: [Float]]` to
   `DiarizationResult`. It is calculated exactly like the existing raw average,
   from the per-window PLDA vectors, with the same speaker assignments and the
   same `centroidSource` filter. Add tests in the SDK's own test suite.
3. Point Biscotti's dependency at the fork, pinned to an exact commit.
4. Open a pull request to ArgMax with the same change, rebased on their `main`.
5. When ArgMax releases the change, point the dependency back at the official
   release.

Creating the fork and opening the pull request are public actions on GitHub.
The developer does them, or confirms them first. Contributor-agreement
decisions belong to the developer.

### 3.6 Which kind the matcher uses

The matcher uses **one kind at a time**. The default is **PLDA**, because it is
designed for this problem. Raw voiceprints are always saved too, so that the
`metrics` tool can compare the two kinds on real data, and the default can
change if raw is better.

Each kind has its own thresholds (§10). Distances in the two spaces are not on
the same scale.

---

## 4. Current-user fact

EventKit marks the invitee who is the current user (`EKParticipant.isCurrentUser`).
The Calendar module reads this value today, but DataStore discards it
(`DataStore+ReadModels.swift:281`: "Not yet populated — always false").

This project saves it with the meeting's calendar data. Then the invitee list in
the prompt marks that person:

```
Invitees:
- Steve Cosman <steve@kiln.tech> (the person who recorded this meeting)
- Daniel Lee <daniel@kiln.tech>
```

This is part of the meeting details, so all prompts get it (speaker
identification, summary, title).

There is no "me" setting, flag, or special person. You tag yourself like any
other person. Voiceprint matching learns your voice quickly, because you are in
every meeting.

---

## 5. Matching

The matcher runs after transcription, before the LLM speaker step. It works
in memory: load, compare, score, discard. There is no index and no cache. A few
thousand voiceprints take a few milliseconds to compare.

### 5.1 Which voiceprints to load

Load each voiceprint record that matches **all** of these conditions:

- Its kind is the matcher's kind (§3.6), and its embedding space is the space
  of the new meeting's voiceprints of that kind.
- Its transcript is the **preferred** transcript of its meeting.
- Its meeting is not the meeting that we are matching.

The preferred-transcript rule stops a meeting that was transcribed two times
from counting two times.

Normalize each loaded vector, and the new speaker's vector, to length 1.
SpeakerKit does not normalize. Remove each vector with length zero:
SpeakerKit's distance function returns `1.0` for these, and that value looks
like a real measurement.

### 5.2 Scoring

For one new speaker:

1. Calculate the distance to each loaded voiceprint. Remove each voiceprint with
   a distance more than `R` (the maximum distance for this kind).
2. For each remaining voiceprint, read the speaker tag (§3.2). Put voiceprints
   with no tag aside for §5.4. Group the others by person.
3. For each person:
   1. **One vote per meeting.** Keep only the closest voiceprint from each
      meeting. Sometimes SpeakerKit splits one human into two diarization
      speakers. This rule stops that meeting from counting two times.
   2. **Best 5 meetings.** Keep only the 5 closest. Then a person with 200
      meetings does not win only because of volume.
   3. **Weight** each kept voiceprint:

      ```
      weight = tagWeight × speechWeight

      tagWeight    = 1.0  for a confirmed tag
                   = 0.4  for an inferred tag
      speechWeight = min(1, speakingTime / 60 seconds)
      ```

      A confirmed tag counts more than an inferred tag, but both count. A
      speaker who talked for a short time gives a less reliable voiceprint.

   4. **Add up the score:**

      ```
      closeness = 1 − distance / R          // from 0 to 1
      score     = sum of (weight × closeness)
      ```

   5. **Calendar increase.** If the meeting has calendar invitees and the
      person's email matches one (case is ignored), multiply the score by
      `1.5`.

      This increases the score. It does not exclude people who were not
      invited. Sometimes a recording links to the wrong calendar event, or a
      person joins without an invite. If we excluded those people, the matcher
      could not identify them.

The **reported distance** for a person is the distance of their closest
confirmed voiceprint. If the person has no confirmed voiceprint, it is the
closest of all their voiceprints. The score decides the order. The reported
distance decides the confidence level.

### 5.3 Confidence levels

`P1` is the person with the highest score. `P2` is the second highest.

| Level | Condition |
|---|---|
| `none` | No voiceprint is inside `R`. |
| `ambiguous` | `score(P2) ≥ 0.6 × score(P1)`, or the reported distances of `P1` and `P2` are within `0.05`. |
| `high` | Reported distance ≤ the high limit, **and** ≥3 meetings counted, **and** ≥2 of them confirmed, **and** `score(P2) ≤ 0.35 × score(P1)`. |
| `medium` | Reported distance ≤ the medium limit, **and** (≥1 confirmed meeting **or** ≥3 inferred meetings). |
| `low` | Inside `R`, but not `high` or `medium`. |

`high` needs three different conditions together. It is rare on purpose: the
matcher must not claim more than its evidence supports. Only the user's own
tags are certain.

**All numbers in §5 are first estimates.** For raw voiceprints, the only
measured reference is `R = 0.6`: SpeakerKit uses this number to decide "same
speaker" inside one recording (see `sdk_findings.md` §2). For PLDA there is no
reference at all. The first estimates for PLDA are the same numbers as raw.
The project ends with a calibration pass (§9.3) that sets both from real data.

### 5.4 Unnamed voices that occur again

Count the voiceprints inside `R` that have no speaker tag, one per meeting. If
there are two or more, and no person matched, the report says:

```
Speaker 5: voice matches an unnamed speaker from 4 earlier meetings.
```

This tells the LLM that the voice is a regular participant, so a name in the
transcript probably belongs to them. When the speaker gets a name, all those
earlier meetings become linked to that person (§3.2).

We do not group unnamed voiceprints with each other. We compare each one only
with the new speaker.

### 5.5 Feedback loop

The LLM can accept a wrong `medium` match. Then a new inferred tag goes to the
wrong person, and the next wrong match becomes stronger. The design limits this:

- An inferred tag has a weight of 0.4. A confirmed tag has a weight of 1.0.
- `high` needs confirmed tags.
- The `metrics` tool measures only against confirmed tags, so the loop cannot
  make the measurements wrong.

We add no other protection now. If the loop is a real problem, `metrics` will
show it.

---

## 6. Who sets names

The LLM makes all name decisions. The matcher never writes a speaker tag. It
only supplies the report.

The existing rules do not change:

- The user's tags are never changed by the LLM. `DataStore.setSpeakerAssignments`
  already skips tags with `userSet == true`.
- The LLM writes inferred tags (`userSet == false`).

When the LLM does not run (AI features off, or no model), the voiceprints are
still saved. They cost nothing, and they are ready when the LLM runs. Name
quality without the LLM does not change.

---

## 7. The report for the LLM

### 7.1 Location

A new `<voiceprint_matches>` block in the first user message of the speaker
step, made by `IntelligencePrompts.analysisFirstUser`. It goes after
`<user_speaker_person_mapping>` and before `<transcript>`.

The block is omitted when there are no earlier voiceprints to compare with.

The report is plain sentences, not a table. The model is a small local LLM, and
sentences are easier for it than a structure that it must parse.

### 7.2 Content

The block has two parts. The per-speaker part gives facts only. It does not
tell the LLM what to decide. It lists only speakers that the user has not
tagged; the prompt already says that user tags are correct.

```
<voiceprint_matches>
Voiceprint history: 47 earlier meetings, 23 with names that the user confirmed.

Speaker 1: high confidence match to Steve Cosman <steve@kiln.tech>. Heard in 12
earlier meetings, 9 confirmed by the user.
Speaker 2: medium confidence match to Daniel (no email). Heard in 8 earlier
meetings, 1 confirmed by the user.
Speaker 3: voice is close to more than one known person: Sam <sam@kiln.tech>
(6 meetings, 4 confirmed by the user) and Samantha (no email) (3 meetings, 0
confirmed by the user).
Speaker 4: no match to any earlier speaker.
Speaker 5: voice matches an unnamed speaker from 4 earlier meetings.
Speaker 6: no voiceprint available for this speaker.

Invitees with voiceprint history:
steve@kiln.tech: 12 earlier meetings. Matches Speaker 1.
daniel@kiln.tech: 8 earlier meetings. Matches no speaker in this recording.
priya@kiln.tech: no voiceprint history.
</voiceprint_matches>
```

Rules for the content:

- A person shows as `Name <email>`, or `Name (no email)`.
- A person who is not an invitee, in a meeting that has invitees, gets
  `(not invited)` after the name.
- `low` matches show as "low confidence match to …".
- "No voiceprint available" is for a speaker that SpeakerKit gave no voiceprint
  (§3.3). "No match" would suggest a new person, which we do not know.
- The invitee part lists only invitees with an email, in invite order, and
  leaves out persons that the user already tagged in this transcript.

The invitee part gives the LLM new information. "daniel@kiln.tech matches no
speaker" tells it that Daniel was invited but his voice is not in this
recording. Then the LLM is less likely to select Daniel for a voice with no
match.

### 7.3 Instruction text

`speakerTaskInstructions` gets this text, one time:

```
If a <voiceprint_matches> section is provided, it compares each speaker's voice
with speakers from earlier meetings. Voice evidence and transcript evidence are
independent. When they agree, that is strong evidence. A high confidence match
with an email is normally correct. A speaker with no match is probably new;
identify them from the transcript. Do not invent an email that is not listed.

The known-people list can contain more than one entry for the same human. For
example, one meeting can record only a first name, and another meeting can
record a full name with an email.

When a speaker's voice is close to more than one known person, use the names
to decide:
- If the names can refer to the same human (a short form, a nickname, or a
  name and a matching email), treat them as one person and use the entry that
  has an email.
- If the names clearly refer to different people, their voices are only
  similar. Use the transcript to choose between them, or leave the speaker
  unassigned.
```

The text has no example names on purpose. Small models often copy example
names into their output.

The output format does not change (`<speakerIndex> | <Full Name> |
<email-or-blank>`, read by `SpeakerMappingParser`).

### 7.4 AI tests

Add LLM tests to the `make test-ai` set, so the prompt behavior is measured:

| Case | Report content | Expected result |
|---|---|---|
| Same human, two entries | Speaker close to `Sam <sam@kiln.tech>` and `Samantha (no email)`; transcript says "Samantha" | Speaker set to Sam/Samantha. The email is `sam@kiln.tech` or blank, never a different email. See the known limit below. |
| Different humans, similar voices | Speaker close to "Dave" and "Amit"; transcript says "thanks, Amit" | Speaker set to Amit |
| High confidence match | Speaker 1 high match to `Steve <steve@kiln.tech>`; no name in transcript | Speaker 1 set to Steve with the email |

**Known limit (measured 2026-10-01, Gemma 4 12B, thinking off).** In the
same-human case, the model selects the name from the transcript ("Samantha")
and leaves the email blank. It does not copy the email from the other entry
(`Sam <sam@kiln.tech>`). With thinking on, the model gives `sam@kiln.tech`, but
the speaker turn takes about 56 s instead of about 4 s, so thinking stays off.
Eight prompt-only changes did not fix it: an explicit rule, a worked example, an
email rule in the output format, "Prefer email if available" at three places,
removing the "do not invent" rule, and removing the "(no email)" label. Adding
an "emails listed" line to the report fixed the email but assigned the same name
to a second speaker. The result is partial, not wrong: the speaker gets the
correct name, and the user can add the email.

---

## 8. Debug window

A developer tool inside the app, compiled only in `DEBUG` builds.

**Entry:** right-click a speaker label in a transcript, then select
**Voiceprint Debug…**. A normal click on the label still opens the speaker-tag
sheet.

**The window shows:**

1. A selector for the voiceprint kind: PLDA or raw. The default is the
   matcher's kind.
2. The exact `<voiceprint_matches>` text that the LLM gets for this meeting,
   with a Copy button.
3. For the selected speaker: the confidence level, and a table of **all**
   candidate people (person, score, reported distance, meetings counted,
   confirmed meetings, invited).
4. The 15 nearest voiceprints: meeting title and date, tagged person or
   "unnamed", confirmed or inferred, distance, speaking time. This includes
   voiceprints outside `R`, marked as outside, so that near misses are visible.
5. A database summary: embedding space, number of voiceprints, number of
   meetings.

The window works for all speakers, including speakers that the user already
tagged. The LLM report leaves those out, but for debugging, "does my tagged
Steve match Steve?" is the most useful check.

The window calculates again each time it opens. You can change a tag, open it
again, and see the effect. It is read only.

It uses the same matcher code as production, so it always shows the real
calculation.

---

## 9. Developer tools

One command-line program, `voiceprint-cli`, in `Packages/BiscottiKit`. That
package already depends on the code that the tool needs (`DataStore`,
`Transcription`). This follows the current pattern: `transcribe-cli` is in the
package that it uses.

Both commands write progress and messages to **stderr**, and results to
**stdout** (research Gotcha #15). Both refuse to run while the Biscotti app is
open: opening the database can migrate it, and two programs must not do that at
the same time.

These tools are not part of the app.

### 9.1 `voiceprint-cli backfill`

```
voiceprint-cli backfill [--store PATH] [--dry-run] [--limit N] [--meeting UUID] [--json]
```

Makes voiceprints from meetings that already exist. Then matching works from
the first day, not after many new meetings.

For each meeting that has a preferred transcript, audio files, and a voiceprint
kind missing in the current space:

1. Run speaker detection again on the saved audio. Do **not** run transcription
   again.
2. Link each new speaker to the old speaker number (see below).
3. Add the missing voiceprint records to the preferred transcript.

It only adds voiceprint records. It does not change transcripts, speaker tags,
summaries, or titles. If a run gives bad results, it costs only time, not data.

**Speaker numbers change between runs.** The new "Speaker 1" can be the old
"Speaker 2". So the tool cannot use the new numbers directly. It compares the
new speaker time ranges with the saved transcript segments, and links each new
speaker to the old speaker that has the most overlap. If the link is not clear,
the tool skips that speaker and reports it.

`--dry-run` lists what the tool would do, without running speaker detection,
and writes nothing.

### 9.2 `voiceprint-cli metrics`

```
voiceprint-cli metrics [--store PATH] [--kind plda|raw|both] [--sweep] [--json]
```

Read only. This tool measures the correct values for the estimates in §5, and
compares the two voiceprint kinds. The default is `both`: the two results are
shown side by side.

**Method:** for each meeting that has confirmed tags, hide all voiceprints from
that meeting, match its speakers against the other meetings, and compare the
result with the confirmed tag.

It hides the **full meeting**, not only one speaker. Other speakers from the
same meeting have the same microphone, room, and time. If they stay visible,
the results look better than they are.

The calendar increase is not used here: the tool measures the voice signal
alone.

It reports, for each kind:

- **Accuracy:** the percentage of correct best matches, in total and for each
  confidence level. `high` must be almost always correct, or the level is
  wrong.
- **Error rates for each `R`:** false matches and missed matches over a range of
  `R` values, as a table, with the point where the two rates are equal. This
  shows how often matches would have been correct.
- **Confused pairs:** the pairs of people that are most often mixed up. This
  shows similar voices, and also two `Person` rows for one human.
- **Coverage:** how many confirmed people have at least 1, 3, and 5 meetings,
  and the distribution of speaking time. This shows if bad accuracy comes from
  the thresholds or from too little data.
- **Possible wrong tags:** confirmed people whose own voiceprints are far apart.
  Usually a wrong tag or a SpeakerKit error.

`--sweep` shows the full table for each `R`. `--json` gives machine-readable
output.

### 9.3 Calibration pass

The last step of this project: run `backfill` and then `metrics` on the
developer's real database. Use the results to set the first thresholds for both
kinds, and to confirm or change the default kind. Record the results and the
chosen values in this project's specs.

This step needs the real database and the SpeakerKit models, so the developer
runs it.

---

## 10. Configuration

There are no user settings.

| Constant | Default |
|---|---|
| Matcher kind | PLDA |
| `R` (maximum distance), per kind | `0.6` (both, until §9.3) |
| `high` distance, per kind | `0.35` |
| `medium` distance, per kind | `0.50` |
| Best meetings per person | `5` |
| Inferred tag weight | `0.4` |
| Full speaking time | `60s` |
| Calendar increase | `1.5` |
| `centroidSource` | `.trainableOnly` |

All are code constants in one type. Users cannot measure these values, so
settings would only cause problems. In one type, the `metrics` tool can test
other values, and a change is a one-file edit.

---

## 11. Constraints

- **Speed.** Matching is a full scan in memory. Target: less than 50 ms for
  5,000 voiceprints.
- **Storage.** About 1.5 KB for each speaker (raw + PLDA). 1,000 meetings × 3
  speakers is about 4.5 MB.
- **No added model time.** Both kinds come from the speaker detection that
  already runs. Only `backfill` runs speaker detection again.
- **XPC.** The transcription result already goes through XPC as JSON.
- **SwiftData.** SwiftData cannot load collection types such as `[Float]` from
  disk in SPM modules (see the comment on
  `TranscriptRecord.vocabularyUsedData`). Vectors are stored as `Data`.
- **Privacy.** Voiceprints are biometric data. They never leave the device and
  are not synced. When a meeting is deleted, its transcripts are deleted, and
  their voiceprints are deleted with them. The debug window and the logs never
  show vector values.

---

## 12. Not in scope

- **New UI in release builds.** The current speaker-tag sheet already lets the
  user confirm and correct names. The only new UI is the debug window (§8).
- **A "me" setting or flag.** The user tags themselves like any other person.
- **The microphone signal** (comparing loudness on the microphone and the
  computer audio). It helps only until the user has tagged themselves a few
  times, and it costs too much for that.
- **The matcher setting names**, with or without the LLM.
- **Merging `Person` rows.** The matcher accepts more than one row for one
  human, and the LLM decides.
- **Voice registration from a short clip.** SpeakerKit has no function for this.
- **Removing bad windows inside one meeting.** SpeakerKit does not expose the
  per-window vectors. We limit bad data across meetings only (§5.2). A later
  SpeakerKit patch could expose them.
- **Matching during a recording.**
- **Converting voiceprints between embedding spaces.**
- **Sync** (roadmap Project 12).
