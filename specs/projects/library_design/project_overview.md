## Package & System Design

We want to design how this app is structured. See app_overview.md, but we want self contained well tested swift packages, and a very thin app layer.

This project is to design the library structure. Not exact interfaces, but responsibilities. Plus the order to build the app in (dependency graph).

Note: what's a component in a bigger package vs it's own package: I don't have strong opinions on. I'm not an expert swift designer, and don't know the tradeoffs.

Components I can think of:
 - AudioRecorder: records audio to disk
 - AudioTranscriber: TTS and diterization, model downloads, memory mgmt, etc
 - DataStore: our SwiftData data model, and related utilities
 - UI: Swift UI componentns for app window and menu bar
 - Background app (the one that runs when no window is open, but can record meetings, render menu)
 - App window logic
 - Notificaiton manager
 - Permission manager
 - Actual app
 - Events: wraper for eventKit. TBD if needed or if direct API is fine, don't add if not needed. But if we're adding sufficient wrappig logic, yeah.
 - Pattern matching: load remote json, and pattern match bundle IDs -> app names, or links -> known meeting platforms.
 - Probably a bunch more, see app overview

### Goals

 - Maximal testability without running the actual app.
 - Dependency graph sane, and drives implmentation order.
 - Implementation order sorted out, and front loading risks (we can build UI, but can we build fast local TTS?). 
   - Front load risk, back load P2/P3.
   - End up with workable app asap, all optional features come after.
   - Allow for broad agentic implementation: backend is tested with unit tests, no need for human until final stages of integrating into UI
 - "Great swift design", whatever that is. I'm not sure if small package or compoentns of package is the way. You advise. Idomatic, quality codebase for swift.
 - app should be a thin layer of things that can't really be unit tested anyway. Minimal or no need for xcodebuild

### Deliverable

 - First an overall plan of our system design
 - Interactive review w Steve