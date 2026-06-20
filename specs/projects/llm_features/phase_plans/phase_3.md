---
status: complete
---

# Phase 3: AppCore wiring & auto-run

## Overview

Wire `Intelligence` into `AppCore` so that `stopRecording()` triggers `runAutoEnhancements` after `transcribe()` completes. Add `Intelligence` as a dependency of `AppCore` in Package.swift. Update `AppCore.init` to accept an `Intelligence` parameter, build it in the `live` factory with real `LiveLLMRunner` + `LiveModelProvider`, and provide a no-op fake in `PreviewAppCore` and `CoreFixture`. Embed `BiscottiLLM.xpc` and the `LocalLLM` package in the main app target (`project.yml`) so `build-app` is green with the framework linked.

## Steps

1. **Package.swift**: Add `"Intelligence"` to `AppCore`'s target dependencies. Add `"Intelligence"` to `BiscottiTestSupport`'s dependencies. Add `"Intelligence"` to `AppCoreTests`'s dependencies.

2. **AppCore.swift**: Add `public let intelligence: Intelligence` property. Add `Intelligence` import. Update `init` to accept `intelligence: Intelligence` parameter.

3. **AppCore.swift stopRecording()**: Inside the `pendingTranscriptionTask` Task, after `await transcription.transcribe(meetingID:)`, add `await intelligence.runAutoEnhancements(meetingID: meetingID)`.

4. **AppCore+Live.swift**: Import `Intelligence`. Build `LiveModelProvider`, `LiveLLMRunner`, and `Intelligence` in the `live` factory. Pass `intelligence` to `AppCore.init`.

5. **PreviewAppCore.swift**: Import `Intelligence`. Create preview fakes for `LLMRunning` and `ModelProviding`. Build a preview `Intelligence` and pass it to `AppCore.init`.

6. **CoreFixture.swift**: Import `Intelligence`. Add `intelligence: Intelligence` to `CoreFixture`. Update `makeCoreFixture` to build a fake `Intelligence` (using `FakeModelProvider` + `FakeLLMRunner` from IntelligenceTests, or inline fakes) and pass it through. Expose `intelligence` on the fixture.

7. **App/project.yml**: Add `LocalLLM` package reference. Add `LocalLLM` product dependency to Biscotti target. Add `BiscottiLLM` XPC service target (mirroring ManualTestApp). Add `BiscottiLLM` embed dependency to Biscotti target. Add `Intelligence` product dependency to Biscotti target.

8. **Write AppCore+Intelligence tests** in AppCoreTests: verify `stopRecording` triggers `runAutoEnhancements` after transcription (via fake intelligence); verify it does NOT run when model not downloaded.

## Tests

- `stopRecordingTriggersAutoEnhancements`: Start recording, stop, await pending transcription, verify `intelligence.runAutoEnhancements` was called for the meeting.
- `stopRecordingSkipsEnhancementsWhenNoModel`: Same flow but with model not downloaded, verify no LLM session opened.
