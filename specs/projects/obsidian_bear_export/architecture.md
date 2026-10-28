---
status: complete
---

# Architecture: Send meeting notes to Obsidian, Bear and Apple Notes

Read `functional_spec.md` first. It holds all behaviour and texts. This doc says where the code goes,
names the types, and lists the tests. There is no new module, and there are no App-target changes.

## 1. Placement

| Layer | Where | Contents |
|---|---|---|
| Data | `DataStore` | `ExportDestination`, `SentExport`, `Meeting.sentExports`, store API, `MeetingDetailData.sentExports` |
| Pure logic | `ImportExport/SendTo/` (existing module; deps DataStore + Formatting) | source, markdown, tags, filenames, encoding, hash, payload, plan, decision |
| Effects | `AppCore/AppCore+SendTo.swift` + `AppCore/SendEnvironment.swift` | detection, open URL, file hand-off, open app, clipboard, record write |
| Icons | `DesignSystem/ExportIcons.swift` + `Resources/Icons/*.svg` (already copied) | template `NSImage`s |
| UI | `MeetingDetailUI` | buttons, `…` submenu, alert, VM state |

Use the existing conventions: `swiftSettings: warningsAsErrors`, swift-testing, and `Logger(subsystem: "net.scosman.biscotti", category: "SendTo")`. Logs contain only the destination, the outcome and byte counts. They never contain content or titles.

## 2. Data (`DataStore`)

`DataStore/Models/SentExport.swift`: `ExportDestination` (`obsidian`, `bear`, `appleNotes = "apple-notes"`; `CaseIterable` order = UI order) and `SentExport` exactly as in functional spec §5.

`Meeting.swift`, using the `TranscriptRecord.vocabularyUsed` pattern:
```swift
/// JSON-encoded backing store for `sentExports`. Additive -- defaults empty, no migration.
private var sentExportsData = Data()
@Transient public var sentExports: [SentExport] { get { lenient decode ?? [] } set { encode } }
```

`DataStore/DataStore+SentExports.swift`:
```swift
func sentExports(meetingID: UUID) throws -> [SentExport]            // [] if the meeting is missing
func recordSentExport(_ export: SentExport, meetingID: UUID) throws  // replaces the same destination; no-op if the meeting is missing
```
`MeetingDetailData` gains `sentExports: [SentExport]` (init default `[]`), populated in `meetingDetail(id:)`.

## 3. Pure logic (`ImportExport/SendTo/`)

All types are `public`, `Sendable` value types or `enum` namespaces. There is no AppKit.

```swift
// ExportDestination+Info.swift
public enum DestinationDetection: Equatable { case urlScheme(String), bundleID(String) }
public extension ExportDestination {
    var displayName: String          // "Obsidian" / "Bear" / "Apple Notes"
    var detection: DestinationDetection  // .urlScheme("obsidian"), .urlScheme("bear"), .bundleID("com.apple.Notes")
}

// ExportSource.swift
public struct ExportSource: Sendable, Equatable {
    public var meetingID: UUID; public var title: String; public var start: Date
    public var durationMinutes: Int?; public var attendees: [String]
    public var summary: String; public var notes: String; public var tags: [String]
    public init(detail: MeetingDetailData)
    public var hasContent: Bool      // summary or notes non-empty after trimming
}

// SendMarkdown.swift — functional spec §3
public enum SendMarkdown {
    static func body(_ s: ExportSource, timeZone: TimeZone) -> String
    static func obsidianFrontmatter(_ s: ExportSource, tags: [String], timeZone: TimeZone) -> String
    static func notesTagFooter(_ tags: [String]) -> String   // "#biscotti #project-x"
}

// SendTags.swift — functional spec §4
public enum SendTags { static func tags(_ raw: [String], for d: ExportDestination) -> [String] }

// SendFilename.swift — functional spec §7.4
public enum SendFilename {
    static func sanitize(_ title: String) -> String                     // Notes file name
    static func obsidianName(_ s: ExportSource, timeZone: TimeZone) -> String  // "<title> <yyyy-MM-dd>"
}

// StrictPercentEncoder.swift
public enum StrictPercentEncoder {
    static func encode(_ v: String) -> String  // allowed set built from the literal ASCII "A-Za-z0-9-._~"
    static func query(_ pairs: [(String, String)]) -> String
}

// SendPayload.swift
public struct SendPayload: Sendable, Equatable {
    public let destination: ExportDestination
    public let markdown: String      // exactly what is sent (and what the clipboard fallback copies)
    public let tags: [String]
    public let contentHash: String   // SHA-256 hex of markdown + "\n" + tags.joined(",") (CryptoKit)
    public static func build(_ s: ExportSource, for d: ExportDestination, timeZone: TimeZone) -> SendPayload
}

// SendPlan.swift
public enum SendPlan: Equatable {
    case openURL(URL)
    case tooLarge(markdown: String)
    case handOffFile(fileName: String, contents: String)   // fileName includes ".md"
    public static let maxURLBytes = 500 * 1024
    public static func make(_ p: SendPayload, source: ExportSource, timeZone: TimeZone) -> SendPlan
}

// SendDecision.swift
public enum SendDecision: Equatable {
    case send
    case alreadySent(sentAt: Date, changed: Bool)
    public static func decide(_ records: [SentExport], for d: ExportDestination, currentHash: String) -> SendDecision
}
```

Notes:
- **Payload by destination:**
  - Obsidian: `obsidianFrontmatter + body`.
  - Bear: `body`.
  - Notes: `body + "\n" + notesTagFooter + "\n"`. The blank line comes from the trailing `\n` of the body.
- **`SendPlan.make`:**
  - Obsidian: `obsidian://new?` + `query([("name", obsidianName), ("content", markdown)])`.
  - Bear: `bear://x-callback-url/create?` + `query([("text", markdown), ("tags", tags.joined(",")), ("open_note", "yes")])`.
  - For both, if `urlString.utf8.count > maxURLBytes`, the result is `.tooLarge`.
  - Notes: `.handOffFile(sanitize(title) + ".md", markdown)`.
- **Dates:** a POSIX `DateFormatter` built per call: `en_US_POSIX`, Gregorian, the injected `TimeZone`.
- **Character handling:** truncate on `Character` boundaries. The tag "letter or digit" test is `CharacterSet.letters ∪ .decimalDigits ∪ .nonBaseCharacters` per scalar.

## 4. Effects (`AppCore`)

```swift
// SendEnvironment.swift — every OS touch, swappable in tests
public struct SendEnvironment: Sendable {
    var appURLForScheme: @Sendable @MainActor (String) -> URL?   // NSWorkspace.urlForApplication(toOpen:)
    var appURLForBundleID: @Sendable @MainActor (String) -> URL? // NSWorkspace.urlForApplication(withBundleIdentifier:)
    var openURL: @Sendable @MainActor (URL) -> Bool              // NSWorkspace.open
    var openFile: @Sendable @MainActor (URL, URL) async throws -> Void  // open([file], withApplicationAt:, configuration: activates)
    var openApp: @Sendable @MainActor (URL) -> Void              // openApplication(at:configuration: activates)
    var writePasteboard: @Sendable @MainActor (String) -> Void
    var tempRoot: @Sendable () -> URL                            // FileManager.default.temporaryDirectory
    var now: @Sendable () -> Date
    var timeZone: @Sendable () -> TimeZone
    public static let live: SendEnvironment
}
```
`AppCore.init` gains `sendEnvironment: SendEnvironment = .live`, stored as `let sendEnvironment`. This follows the `mcpServer` optional-param pattern, so existing fixtures still compile.

```swift
// AppCore+SendTo.swift
public enum SendOutcome: Equatable { case sent, copiedToClipboard, failed }
public extension AppCore {
    func installedSendDestinations() -> [ExportDestination]   // CaseIterable order, filtered by detection
    func send(_ source: ExportSource, to d: ExportDestination) async -> SendOutcome
    func openDestinationApp(_ d: ExportDestination)
}
```

**`send`:**
1. Get the app URL from the detection. If it is nil → `.failed`.
2. Build the payload, then the plan.
3. `.openURL` → `openURL`. Return false → `.failed`.
4. `.tooLarge` → `writePasteboard(markdown)` → `.copiedToClipboard`, with no record.
5. `.handOffFile` → write to `tempRoot()/biscotti-export/<UUID()>/<fileName>` (create the folder, atomic UTF-8 write), then `await openFile(file, appURL)`. If anything throws → `.failed`.
6. On success → `try await store.recordSentExport(SentExport(destination:, contentHash:, sentAt: now()), meetingID:)`. If the store throws, log it and still return `.sent`, because the note was sent.

**Detection caching:** this is a coding-time decision (functional spec §8).
- Measure the three lookups in a debug build or a test.
- If they are fast enough, `installedSendDestinations()` looks up live.
- If not, add an in-memory cache on AppCore, refreshed in `onLaunch()` and on `didBecomeActiveNotification`.
- Record the result in functional spec §8.

## 5. Icons (`DesignSystem`)

```swift
public enum ExportIcons {
    public enum Kind: String { case obsidian = "obsidian-outline", bear = "bear-outline-plain", appleNotes = "apple-notes-outline" }
    public static func image(_ k: Kind) -> NSImage   // cached; isTemplate = true
}
```
- Load the image with `Bundle.module.url(forResource:withExtension: "svg")`. If that fails, retry with `subdirectory: "Icons"`. Then use `NSImage(contentsOf:)` (NSImage renders SVG on macOS 14+).
- If the load fails, return an empty template image and fire `assertionFailure`.
- **Fallback if NSImage cannot render the SVGs:** convert the path data to SwiftUI `Shape`s. Do not use an asset catalog, because CLI `swift build` does not compile `.xcassets`.
- MeetingDetailUI maps `ExportDestination` → `Kind`, so DesignSystem does not depend on more modules.

## 6. UI (`MeetingDetailUI`)

**ViewModel (`MeetingDetailViewModel`):**
- `sentExports: [SentExport]`, set from `detail.sentExports` in `refreshData()`.
- `var sendSource: ExportSource?`: `ExportSource(detail:)` overlaid with the live title, `summaryText`, `notes` and tags. This includes edits that are still in the autosave debounce.
- `var sendDestinations: [ExportDestination]`, from `core.installedSendDestinations()`.
- `var canSend: Bool`, from `sendSource?.hasContent`.
- `var sendAlert: SendAlert?`:
  ```swift
  enum SendAlert: Identifiable, Equatable {
      case alreadySent(ExportDestination, sentAt: Date, changed: Bool)
      case tooLarge(ExportDestination)
  }
  ```
- `func sendTapped(_ d:) async`:
  1. Build the payload.
  2. `SendDecision.decide`. `.alreadySent` → set the alert. `.send` → `performSend(d)`.
- `func sendAgain(_ d:) async` → `performSend(d)`.
- `func openApp(_ d:)` → `core.openDestinationApp(d)`.
- `private func performSend(_ d:) async`:
  1. `outcome = await core.send(source, to: d)`.
  2. `.copiedToClipboard` → `sendAlert = .tooLarge(d)`.
  3. Reload `sentExports` from the store.

**View:**
- `MeetingDetailView.tabBar`, after Copy: `ForEach(viewModel.sendDestinations) { SendToButton(destination:, enabled: viewModel.canSend) { Task { await viewModel.sendTapped($0) } } }`.
- New `SendToButton.swift`: `Image(nsImage: ExportIcons.image(kind)).renderingMode(.template).resizable().frame(width: 14, height: 14)`, `.buttonStyle(.borderless)`, `.controlSize(.small)` and `.foregroundStyle(.inkSecondary)`. Tooltip and accessibility label per functional spec §10.2.
- `overflowMenu`: `Menu("Send to") { ForEach(destinations) { Button(displayName) {…} } }.disabled(!canSend)`. Hide the submenu if no destination is installed.
- `.alert` on the detail view bound to `sendAlert`, with the texts and buttons of functional spec §7.4 and §10.4. `<date>` is `sentAt.formatted(date: .abbreviated, time: .omitted)`.

## 7. Tests

**`ImportExportTests/SendTo/`:**
- **Encoder:** space, `/`, `+`, `&`, `#`, `?`, `=`, `,`, newline, emoji, CJK and `é` (NFC and NFD) are encoded; unreserved characters are not.
- **Markdown:** golden body (fixed UUID and date, `America/New_York`); each omission (summary, notes, attendees, duration); duration formats; CRLF; the title fallback; a double render is identical; golden frontmatter with quote, backslash and emoji escaping; the Notes footer.
- **Tags:** parameterized for each destination (spaces, commas, `#`, `/`, digits-only, mixed-case duplicates, a `Biscotti` duplicate, empty after cleanup, order).
- **Filename:** each disallowed character; leading dot; whitespace; the 120-character cut at an emoji ZWJ boundary; empty title; Obsidian `<title> <date>`.
- **Payload/hash:** 64 lowercase hex characters; stable; changes when the title, summary, notes or tags change; differs between destinations.
- **Plan:** golden URLs for Obsidian and Bear (no `+` and no raw `/`, `?` or `&` in values); the size limit at 511,999 / 512,000 / 512,001 URL bytes; Notes → `.handOffFile` with a `.md` name.
- **Decision:** no record → `.send`; same hash → `.alreadySent(changed: false)`; different hash → `changed: true`; another destination's record is ignored.

**`DataStoreTests/SentExportTests`:** round trip; replace for the same destination while the other records stay; missing meeting is a no-op; corrupt data → `[]`; a new meeting → `[]`; `meetingDetail` exposes the records.

**`AppCoreTests/SendToTests`** (fake `SendEnvironment`):
- URL send → record written with the payload hash;
- `openURL` returns false → `.failed` and no record;
- oversize → pasteboard written, `.copiedToClipboard`, no record, no open;
- Notes → the file exists at `tempRoot/biscotti-export/<uuid>/<name>.md` with the payload contents, `openFile` called with the Notes app URL, record written;
- `openFile` throws → no record;
- not installed → `.failed`;
- `installedSendDestinations` order and filtering.

**`MeetingDetailUITests/SendToTests`:** the source includes unsaved edits; `.alreadySent` with `changed` after a notes edit; `.tooLarge` alert; `canSend` false when empty.

**`DesignSystemTests`:** all three icons load, are non-empty and are templates.

Run everything via `mcp__hooks-mcp__test`.

## 8. Manual validation
Phase 3 writes `specs/projects/obsidian_bear_export/manual_validation.md` from functional spec §11. The user runs it on macOS 26 and macOS 15. The findings go back into the functional spec (§8, §11 and §12), and small fixes are made in the same phase.
