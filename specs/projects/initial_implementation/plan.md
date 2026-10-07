
We want to break this into phases.

## Research

Research harder problems: speech to text, diarisation, clean audio channels, monitoring audio devices, system APIs that require manual testing.

Goal: known working reference code we can use in final app. Solve our hardest problems, unblocking all UX design.

## Core Scaffoling

Setup our codebase for prod code. I want a really great codebase
 - linting
 - testing
 - formatting (fix and check)
 - pre-commit hook for linting, testing, etc
 - CI for linting, testing, etc (GH actions)

Also: agent integration. We want to drive everything from claude code. Apple launched new MCP/SDK for xcode, we should use it. Might need to update MacOS but that's fine. Reseach how we can have more reliable testing/builds from both agents and CI, as this has historically been a nightmare (xcodebuild CLI has tons of issues, where as swift CLI is amazing).

## Library Building

Build libraries for tough tech, so the app has clean solid APIs to work with. Really well tested (unit tests, integration tests, and even test-apps for manual validation of system integrations/hardware pipelines e2e). Produces proper swift libraries, we can use in app. Performance concerns addressed (releasing buffers). Deisgn decisions (proper cache directories, etc).

All packaged as ready-to-use swift libraries (test app can be along side, but not in lib).

Basically this step is to take our `experiments` code and productionize it.

 - Speech to text and diarisation: loading/unloading models, downloading models, caching/deleting models, status for all (needs download, errors, download progress, compile model progress, loading models progress, running progress), and of course the core transcibe with speakers API
 - Audio processing: 
  - listen for new audio devices, giving us bundle ID, name and any other IDs (for building UX around new calls). Lightwight, stable, not polling ideally.
  - Record audio: clean start/stop API. Captures system and mic. Saves to a well known cache dir, file cleanup, etc.
  - great memory usage: free buffers when done
  - reasonable compression of audio files for long term storage (AAC LC??)
 - Events/Calendar: prob not needed, but decdie if a wrapper library would help. I assume system one is good enough.

