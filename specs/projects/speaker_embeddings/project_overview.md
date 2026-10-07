---
status: complete
---

# Speaker Embeddings (Voiceprint Database)

Roadmap entry: **Project 11 — Auto-Speaker Identification** (the cross-recording
voiceprint half). See [`specs/projects/initial_implementation/implementation_plan.md`](../initial_implementation/implementation_plan.md).

## Goal

Create a database of voiceprints for people I know, so identifying speakers gets
to be automatic over time. Not just relying on the LLM, but using the distance
between historical voice embeddings and this conversation's voice embedding.

## Our SDK: SpeakerKit

The SDK exposes the speaker embeddings we need.

`Sources/SpeakerKit/DiarizationResult.swift`:

```swift
public private(set) var speakerCentroidEmbeddings: [Int: [Float]]
```

Helpers:

```swift
func centroidCosineDistance(between a: Int, and b: Int) -> Float?
func nearestSpeakerCentroid(to embedding: [Float]) -> (speakerId: Int, distance: Float)?
```

Other technical notes from the research bot (confirmed and extended in
[`sdk_findings.md`](sdk_findings.md)):

- The centroids are in the raw embedder output space — unnormalised, pre-PLDA.
  Cosine ignores magnitude for a single comparison, but if you're updating an
  enrollment by averaging centroids from several clips, L2-normalize each one
  first or your longest/loudest clip dominates the mean.
- Distance is on `[0, 2]`, not `[0, 1]`: 0 is identical direction, 1 is
  orthogonal, 2 is opposite. Easy to mis-set a threshold if you assume the usual
  0–1 cosine-similarity convention.
- `PyannoteDiarizationOptions.centroidSource` controls what feeds the mean.
  Default `.finalAssignment` averages every embedding under the final label.
  `.trainableOnly` filters for purer embeddings, which is better for enrollment
  quality — but it can drop a speaker entirely, so the key may be missing even
  though that speaker appears in segments. Use `if let`, don't force-unwrap.
- They deliberately don't define a same-speaker threshold, and say to calibrate
  for your model, audio, and app. Given we already have verification UI, we're
  well positioned here — log the distances on user-confirmed matches and
  rejections and pick the operating point off our own DET curve rather than
  guessing.

## Design notes

- If we don't already, we need to be clear what's a **confirmed** speaker (set
  by the user) vs **inferred**. We will need this information during matching.
- Calendar invite is a powerful, but optional, signal.
  - If we have emails, great to exact match. Reasonable to expect they were
    present, so we can filter down.
- User tags may be an email, or just a name. Handle both. "Mike" or
  "mike@kiln.tech".
- **Embedding match algorithm**
  - Cosine distance search of past conversation clusters.
  - It should weigh confirmed IDs over inferred IDs, but can use both. If we
    have 25 manually confirmed, no need to use inferred. But inferred can be
    useful too: if in a prior conversation I said "Hi I'm Steve" and this one I
    didn't, this system lets us move that inference over to this conversation
    based on embedding match.
  - Look at scaling/normalization.
  - Some way to trim outliers? A cluster of N is super uniform, but has 1
    outlier.
  - Can be an in-memory build/scan. We're talking low thousands of embeddings
    max. Cosine distance is fast. No index needed.
  - The DB might have many entries per person (a "Steve" I typed, another
    "steve@kiln.tech"). Matching should handle this.
- **Merging this signal with LLM name inference**
  - The LLM-based name inferrer is still pretty powerful. We want to benefit
    from it, and this, together.
  - Run embedding-based matching first. Produce a report for the LLM to read,
    and let the LLM make the final call. Something like:
    - "Speaker 1 has high confidence to be steve@kiln.tech (Steve)\nSpeaker 2
      has medium confidence to be 'Daniel'\nSpeaker 3 matches multiple past
      users: 'sam@kiln.tech' or 'Samantha'.\nSpeaker 4 doesn't match any prior
      speaker."
    - Could also have a report based on emails when we have them:
      "steve@kiln.tech has 12 prior conversations, matches Speaker
      1.\ndaniel@kiln.tech has 8 prior conversations, matches no speaker."
    - Why: the LLM can handle "Sam" vs "Samantha" uncertainty well. The LLM can
      name Speaker 4 using its signals. The LLM can realize the "Dan" referred
      to in meeting audio could be "Daniel". It can handle "Could be Steve or
      Steve Cosman" ambiguity.
  - So: embeddings first → create report for LLM pass → LLM makes final calls.

## Next

Read up on the API from SpeakerKit, its limits, embedding scale, etc. Get the
knowledge we need to design this.

> Done — see [`sdk_findings.md`](sdk_findings.md) for the verified SDK facts and
> the current state of the Biscotti code this project has to build on.
