# Biscotti App

A new MacOS app for recording meetings. Private, local, awesome.

### Overview

- A native MacOS app, written in swift and swift UI
- It records you meetings (audio recording), then uses local speech to text and diatirsation to get a transcript of the meeting
- It stores data in SwiftData. Custom data model. Core one is “Meeting” with attached audio files, transcript data, title, participants, etc
- Uses eventKit access to access your calendar. Knows about upcoming meetings. Copies in relevant information about he meeting into it’s Meeting data model, etc.
- Nice tray icon/app: shows your next upcoming meting, shows when recording, suggests stoping recording when meeting ends
- P2: LLM intelligence: features like “write summary”, “Map ‘Speaker A’ -> name” using transcript (speaker B says “Hi Tom” and tom was participant), “write follow up”. Could be API based of llama.cpp based

## Audio Recording

The app records the meeting to an audio file, and keeps it in our data model (as external file). This allows us to re-process the transcript later with better TTS models as they come out.

- The app must request system audio access. It needs both the microphone (me speaking) and the audio (the other people in meting speaking).
- Focus on really low CPU/memory/NPU usage during meeting. We really just record. No need to load out TTS models, etc. Want a lightweight and rock-solid recorder app. Never crashing is a pretty key feature.
- We save audio recording files, not just transcripts. Let’s us listen to audio, and re-transcribe later with better models. Care about compression level.

### Open Research Question: Audio

- What’s the right MacOS system API for this?
- What’s the right MacOS system permission for this?
- Can we get streams independently? Example my mic vs the meeting audio of others? Would help identify “me” in combined transcript very easily. 
  - Can we save as 2 streams? Later question will ask “should we”
- Can we detect when meetings start and end via system APIs? I assume we see new active streams come in an go? Can I tell it’s an audio stream from “Zoom.app” or “Chrome.app”?
- Which audio format should we use? High quality for voice, but not music fidelity. Reasonable sized files. 48 kbps AAC-LC mono? Something else? Could also record in whatever native format, and covert to “long term storage” format after call.
- P2 Can we stream it to disk, so if app crashes we have partial stream

Create a `experiment` app dedicated to this. Can be simple UI, but we want to use it

- Show streams: be show all stream starting, stopping, identifiers we get from them, etc
- Record stream: confirm our approach for streaming audio to disk, in desired format
- Real UI for testing: unit tests suck at system integration testing, hardware testing, etc.

## Data Model

Use SwiftData for our data store

- Core data model is “Meeting” (maybe named “Event”).
  - title
  - summary
  - attached audio file (not in sqlite, but should sync, swift data has option for this)
  - transcript: data structure. Turn based, speaker IDs. Content of speech.
  - notes: custom notes.
  - etc.
- Automatically syncs across my apple account using native SwiftData options
- Add fields, relationships, and data models as needed. This is high level rough idea.
- Maybe transcripts are their own datamodel, so we can create new version for a meeting (say better model, or better custom vocab), then meeting can show list (defaults to latest, but can see older ones too).

## UI

Two modalities: a great “tray” app, and the core app window.

### Tray App

A lot of users will live in the trap version of the app.

Icon:
- icon only: no meetings starting in next 2 hours
- icon + text for “next meeting”: “1:1 Sam - in 1h52m” (research truncation when we get to this part, we want it to truncate meeting title, not time)
- recording: icon + recording symbol
  - Option 1: red recording dot
  - Option 2: white/system-color dot, but changing opacity every few seconds like a blinking recording LED on old VCR

Body:
- Recording section: state full recording status
  - Not recording: a start recording button
  - Recording: show time counting up, stop button
- Upcoming section: show next 2 meetings
- Past meeting
  - Last 2 inline, links into app window
  - See all
- Open App
- Quit

### App Window

The app window does not need to be open for the app to work. We’re a tray-first app. 

- Left bar is list of items
  - Home: opens Home Screen
  - Recording indicator: if recording shows recording indicator and 
  - “Upcoming”: next 2 upcoming  meetings
  - “Past”: scrollable list of past meetings
- Main app area: right of left bar, takes up most of window
  - Home: Nice welcome screen. TBD content, but prob “start recording” and a preview of upcoming meetings
  - Recording View
  - Meeting View
- Search: 
  - a search bar in top of app lets you search all of your meetings. 
  - As soon as you start typing it takes over main view areas with live filtering search results. A back button in top left of main area closes search.
  - Searches all fields (title people, transcripts). Use simple swiftData search for now (something like splitting terms, LIKE to check presence, return count, weight count title higher than transcript, sort by score). Searches across many fields (title, notes, transcript, participants). Will design details later. Not fancy FTS in V1 but could add later. Perf: we're talking probablly <1000 docs, so not concerned about indexing. Try a filter before we get fancy. We'll optimize if/when needed.

### Onboarding

We'll be a great onboarding wizard, as setup isn't trivial.

 - Approve audio permissions: system audio and mic. Instructions to fix if they deny it.
 - Approve calendard permission, fix or skip if they deny (push fix). Select which calendars they want to monitor for meetings (although maybe this gets moved into settings if we have good "videoconference link detection"). P2: instuct them to connect Google/other Calendar to Apple calendar if missing their key events.
 - Download models: TTS, diterisation, and LLM (later). Needs progress. Needs disk space chceck before starting.
 - Demo (P2). Offer demo: voice says "Hey, welcome. Say someting back and we'll show you our on device transcription. [6 second gap of recording]" -> transcribe and see 2 speakers (app voice and user voice).

## Custom Vocabularies

We want to support custom vocabularies.
- App wide custom vocab list in settings: my company name, my name, weird technology names, internal codewords
- Meeting specific: merge app-wide list with keywords from meeting information: participant names, company names, maybe later even key words from title description (“Project Parakeet Team Meeting” > “Parakeet”)
- Recording specific: a list I add manually to this meeting (post-hoc fix). P3
- Pass the merged list to SDK for better transcripts.

Note: since transcription is now downstream from the pairing of event<>recording, if the user corrects the assiociation (I had 2 meetings at same time, we attached wrong one) 
 1) correction should be possilbe 
 2) I should be able to re-transcribe after changing


## Producing Transcripts

We want to use WhisperKit and SpeakerKit from ArgMax: [argmaxinc/argmax-oss-swift: On-device Speech AI for Apple Silicon](https://github.com/argmaxinc/argmax-oss-swift)

- Use the free SDK to start, not Pro
- Use TTS model NVIDIA Parakeet V3 
- Use diarization model `nvidia/sortformer-v2-1`
- Produces a transcript, which is saved into the Meeting datamodel. Meeting datamodel should be rich and contain as much info as we have out of these tools (we’ll render a subset).
- Both run after meeting is over, not streaming. Both run together in 1 API call.
- Wrap it into a “library” for cleaner testing and separation (roughly `processAudio(audioFile) -> transcriptObject`).
- no model selection/management UI in V1. Hardcode a good pairing we test well
- Note: we know the ArgMax team well, can bug them for help. If there are genuine “which option is better” we can ask the literal experts. We should leverage this, but should queue up our questions to “we obviously read through code, these are good questions” level

### Open Research Questions

I think it makes sense to build a proof of concept wrapper of these libraries with a simple API matching what we need (roughly `processAudio(audioFile) -> transcriptObject`). Goal to wrap this up in simple library we import into app.

Separate project/lib benefits:
- let’s us write test cases around around the APIs more easily
- let’s us send to argmax buddy and say “why this no work”

Questions:
- how do we download models, where are they stored?
- memory caching lifecycle: loading/unloading models needed. Can we do 1 at a time, or need both?
- other technical constraints? Min memory for hardware, old devices not supported (Intel Macs, M1, etc). Anything else
- API design: finalize the API lib exposes (maybe load/unload for memory, etc)
- how do I get it to work?? I don’t know API at all
- What questions should we ask argmax team to make best possible app? Any genuine choices that aren’t clear. At minimum we should draft a “Confirm all this sounds good: [quick overview of approach]”
- Isolation: how do we run this so a crash doesn’t take down app? Thread? Sub-proc? No main thread access, real background worker. 
- 2 streams vs 1: which is better? What does SDK support?
  - send merged to SDK, but use mic vs audio to help identifying me as side analysis
  - send separate streams, time aligned
  - something else??
- Any speaker ID across files? Can we learn what I sound like across many recordings, use that to improve speaker ID over time.
- Custom vocabularies: what’s supported in the SDK, limits, etc.

## EventKit

We use eventKit to get the user’s calendar

Goals:
- show upcoming events in various places
- enrich meetings with context from calendar: title, people, company, description, etc.
  - keep a copy in the data model, don’t assume eventKit link works forever
  - keep the event data together in a sub-item, so we can clear it all in 1 clean swipe if it pairs an event by mistake.
- filter which calendars we include in the app (exclude my family calendar, only show work). Settings shows a list of toggles, 1 for each “calendar”
- read only: we don’t need to write calendar info

### Research Phase

Make a small test app that uses event kit to pull calendar.

- get permission, see UI, approve
- read calendar list
- read events, filtered so specific subset of calendards
- read participants/title/descripiton
- anything else app will require
- Should also produce a report of data available for designing our Meeting data model.
- etc

Goal is a quick sanity check it works well, can get information we need. Can use a combo of unit tests, and manual UI testing to confirm it works (agent drive UI test plan if going that route, builds test UI and instructions, human just clicks and confirms)

Note: for the `experiment` I don’t think we need a library wrapper here like speech - just a proof of concept, generating reference code.

## Notificaitons

We should have excellent notifications

 - At a event start time: pop it in, show link to join call if we can auto-extract, option to record. Some smarts on "meetings that have video conferening links", not any calenar appointment (a flight, dance recitle)
   - Details: button to "Open and Record", secondary option for open and record separately if that's possible in MacOS notifications
 - When an ad-hock meeting starts (Facetime, Slack huddle, one off video converence), as detected by audio APIs, notificaiton to offer to record
 - Stop recording notifications: ask to stop recording when audio from app stops. Ideally notification indicates it's going to automatically in 15s and counts down, and clicking is to keep recording.

## LLM Enhancements

Will add this post V1, but we want to add LLM based intelligence

- Summarize meeting:
  - read the transcript, creates summary
- Extract action items
  - read the transcript, creates action items
- Name speakers
  - sortformer gives us “speaker A” / “speaker B” (confirm) but not “Steve” / “Mike”. An LLM could often figure this out: speaker A says “hi mike” at start, Speaker A is not mike (and if 2 people, B is mike). Speaker B says “hey mike, can you answer that” and speaker C talks next answering (that’s mike)
- Extract custom vocab words from meeting invite: pick out words that might be helpful in custom vocab. Don't need "team"/"John", do need "cipralex"/"Saoirse". Meaningful words relating to topic. 
- Etc.

We could support both private and external models
- Gemma 4 E4B/12B or similar for local, via llama.cpp (I assume there’s a good swift wrapper)
- External via “API key and openAI compatible base url”

## Misc App Reqs

- Settings has a “Launch on startup” option, enabled by default
- We've seen track alignment issues in recording: call comes in 10s after recording starts, and system audio track is off by 10s. This went away, but have seen sub-second drift after. We should investigate 1) tracking clock time of start of alignment, 2) adding silnce in start gaps, 3) If same type of gap is possible in middle (if so, offset won't save us). Note: haven't occured recently, so may be gone.
- P2: system wide keyboard shortcut to start/stop recording. Configurable, disableable.
- we should have a server delivered JSON file with known "meeting" apps. Bundle ID -> name mapping for "Meeting detected" notifications, . This lets us detect their audio/when meeting start, and being server driven json lets us update OTA.
  - also in file: known URL regexes for videoconferenging URLs so we know which events are meetings
- DONE: move from caf recordings to something crash proof. caf AAC-LC are variable rate, so if the process crashes, it's missing the pakt table, and has nothing. FLAC could be better choice?
- The audio-recording data model should be created on start, and linked to the path of the audio file as soon as we start streaming. No point in crash resistent recording, if it ends up orphaned in a temp dir. P2
- P3: Settings screen to see file usage, and delete audio files. Calculates total usage of audio files, and can delete them. Lost ability to playback in app, or to re-transcribe. Later problem for when people have 50GB of audio.
- P3: consider moving from AAC to Opus encoding. Want to keep our crash recovery property (stream is valid if we crash, up until crash), but get Opus' better compression and reduce file sizes. Issue: Opus is supported by CoreAudio, but caf container, which breaks crash recovery. So doing this would either be a lot of work (custom Ogg streaming could work, not native), or a "after recording AAC, convert to Opus for long term archive/compression" (easier, better). Should consider later: could record higher qualtiy AAC stream initially (for crash recovery, 48khz/128kbps since temporary and not sweating storage), then Opus for archival long term storage (smaller, maintains quality). Could even do uncompressed intially (PCM/wav/FLAC). P3: all this does is drop us to 15MB/hour from 28MB/hour, not that important

## Design Style

Exceptionally “Apple” native. Standard controls, HIG compliant. Great use of highlight color. Not “light on design”, but “tight design”. We don’t invent a frivolous visual language to stand out, we feel like Apple’s design team focused on the details.

## Development Stages & Style

We want to start with the “research” tasks. These should be in an `experiments/` folder, each independent. This lets us try a lot of things quickly, without leaving cruft around our core app codebase (the core app won’t even exist yet!). There’s a lighter requirement for tests here: test as it’s helpful, but these are throwaway, so not needed for long term stability.

Research tasks include:
- Audio integration: recording, detecting streams, etc.
- EventKit test app: show we can get events, filter calendars, etc
- ArgMax wrapper: TTS and diertization wrapper. May be upgraded to “library” later so tests here more necessary than other two

We do these first. Once done, all real “technical unknowns” are sorted out, and we can design the app layer at in more detail.

Plan:
- create all experiments without stopping
- Verification phase for each: a set of questions we need to answer interactively using it.

## Stack/Testing/CI/Etc

When we get to starting the app itself, we want really great tooling. CI, linting, testing, etc. There should be a scaffolding stage.

We deliberately keep the app target thin and push essentially everything into Swift packages — not just business logic but view models, navigation, networking, and most UI. The reason is structural: anything reachable by swift build/swift test builds without a simulator, code signing, or the Xcode project graph, which makes it fast, deterministic, and clean for both CI and coding agents. xcodebuild drags all of that in, so we minimize what depends on it. The app target is reduced to the composition root plus the irreducible Apple-platform glue (entitlements, App Intents, extensions, asset catalogs). We still ship an app and still test it, but app/UI tests run as a separate, non-gating CI tier (slower, occasionally flaky); the package test suite is what gates merges. For agentic work on the app shell, agents use `swift` CLI 99% of the time; for rare exceptions it can drive builds through XcodeBuildMCP rather than raw xcodebuild invocations.
