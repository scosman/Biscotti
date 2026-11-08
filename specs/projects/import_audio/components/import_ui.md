---
status: draft
---

# Component: ImportUI (+ shell and App wiring)

## 1. Purpose and scope

A new BiscottiKit library target, `Sources/ImportUI/`, containing:

- **The window drop target:** an AppKit `NSView` drag destination. It reads the drag pasteboard (file URLs and file promises), classifies the items, drives the overlay state and hands `[ImportEntry]` to AppCore on drop.
- **The drop overlay:** a SwiftUI view rendering `DropOverlayState` (`ui_design.md` §2).
- **The Import screen:** `ImportView` + `ImportViewModel` (`ui_design.md` §3).

Also covered here: the edits to `AppShellUI` (root overlay, route, sidebar row, `.fileImporter`) and to the `App` target (the File menu command).

Dependencies: `AppCore`, `AudioImport`, `DataStore`, `DesignSystem`, `Formatting`, AppKit, SwiftUI, UniformTypeIdentifiers.

---

## 2. Window drop target

### 2.1 Overlay state (pure, `DropOverlayState.swift`)

```swift
public enum DropOverlayState: Equatable, Sendable {
    case supported(count: Int)                      // all supported, count >= 1
    case mixed(supported: Int, unsupported: Int)    // both >= 1
    case unsupported(count: Int)                    // all unsupported, count >= 1

    /// nil when the drag carries no file items (text, web link) -> no overlay.
    public static func classify(_ items: [Bool]) -> DropOverlayState?   // true = supported
    public var acceptsDrop: Bool { if case .unsupported = self { false } else { true } }

    // Copy (functional spec §2), unit-tested:
    public var title: String           // "Drop to import" / "Drop to import N files" / "Can't import this file"
    public var subtitle: String
    public var showsFormatLine: Bool   // supported(1), unsupported
    public var skipNotice: (count: Int, text: String)?   // mixed only; singular/plural
    public var isNeutral: Bool         // unsupported
}
```

`title` for `.mixed(supported: 1, _)` is "Drop to import". For `.supported(count: 1)` it's "Drop to import", with subtitle "Biscotti will transcribe and summarize it on your Mac."

### 2.2 `DropTargetModel`

```swift
@MainActor @Observable
public final class DropTargetModel {
    public internal(set) var state: DropOverlayState?   // nil = overlay hidden
    public init()
}
```

The shell owns one instance (in `AppShellViewModel`) and passes it to both the overlay view and the drop view.

### 2.3 `WindowDropView` (AppKit, `WindowDropView.swift`)

```swift
final class WindowDropView: NSView {
    weak var model: DropTargetModel?
    var isEnabled: @MainActor () -> Bool = { true }          // false during onboarding
    var onDrop: @MainActor ([ImportEntry]) -> Void = { _ in }

    override init(frame: NSRect)   // registerForDraggedTypes(Self.draggedTypes)
    static let draggedTypes: [NSPasteboard.PasteboardType] =
        [.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { .init($0) }
}
```

**Click-through hit testing.** The view must never take mouse, scroll or cursor events, but must stay findable as a drag destination:

```swift
override func hitTest(_ point: NSPoint) -> NSView? {
    switch NSApp.currentEvent?.type {
    case .leftMouseDown, .leftMouseUp, .leftMouseDragged,
         .rightMouseDown, .rightMouseUp, .rightMouseDragged,
         .otherMouseDown, .otherMouseUp, .otherMouseDragged,
         .mouseMoved, .mouseEntered, .mouseExited, .scrollWheel,
         .cursorUpdate, .magnify, .rotate, .swipe, .smartMagnify, .pressure, .none:
        return nil
    default:
        return super.hitTest(point)   // drag-destination lookup
    }
}
```

This works whether or not AppKit's drag-destination search goes through `hitTest(_:)`. During an external drag our app receives no mouse events, so `currentEvent` isn't one of the listed types. In-app drags, where the event is `.leftMouseDragged`, pass through, which is fine: Biscotti has no internal file drags. Override `acceptsFirstMouse` to return false. Install no tracking areas.

**`NSDraggingDestination`:**

| Method | Behavior |
|---|---|
| `draggingEntered(_:)` | `guard isEnabled()`, else return `[]`. `let classes = classify(info.draggingPasteboard)` (§2.4), then `model.state = DropOverlayState.classify(classes)` (animated by the view). Cache the operation: `.copy` if `state?.acceptsDrop == true`, else `[]`. Return it. |
| `draggingUpdated(_:)` | Return the cached operation. |
| `draggingExited(_:)`, `draggingEnded(_:)`, `concludeDragOperation(_:)` | `model.state = nil`. |
| `prepareForDragOperation(_:)` | `state?.acceptsDrop == true`. |
| `performDragOperation(_:)` | `let entries = buildEntries(info)` (§2.5), `model.state = nil`, `onDrop(entries)`. Return `!entries.isEmpty`. |

Set `wantsPeriodicDraggingUpdates = false`.

### 2.4 Pasteboard classification

Iterate `pasteboard.pasteboardItems ?? []` in order, building `[(kind, supported)]`:

1. **File URL.** If `item.string(forType: .fileURL)` parses as a file URL → `ImportFileClassifier.isSupported(fileURL:)`.
2. **File promise.** Else, if the item's types intersect `NSFilePromiseReceiver.readableDraggedTypes` → it's a promise item. Promise receivers come from `pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self])` (one per promise item, in order). Take the next one. Supported iff `receiver.fileTypes.first` passes `ImportFileClassifier.isSupported(typeIdentifier:)`.
3. **Otherwise** the item isn't a file (text, URL, image data) and is ignored. It counts toward neither number.

The result of `[Bool]` feeds `DropOverlayState.classify`. Factor the walk into a testable function over a small protocol (`PasteboardItemSource`) so the tests can feed synthetic items without a real drag:

```swift
struct DraggedItemDescriptor: Equatable { enum Kind { case file(URL), promise(typeIdentifier: String?, index: Int) } let kind: Kind }
static func describe(_ pasteboard: NSPasteboard) -> [DraggedItemDescriptor]
static func supportedFlags(_ items: [DraggedItemDescriptor]) -> [Bool]
```

### 2.5 Building entries on drop (incl. promises)

For each **supported** descriptor, in order:

- **`.file(url)`** → `.file(url)`.
- **`.promise`** → for receiver *k*:
  1. Make `dir = FileManager.default.temporaryDirectory/"Biscotti-Import"/UUID()` (`createDirectory`).
  2. Create `let future = PromisedFile()`: a small `@unchecked Sendable` class holding a `CheckedContinuation`. It resolves on the **first** reader callback; later callbacks are ignored. It supports awaiting before or after resolution.
  3. Call `receiver.receivePromisedFiles(atDestination: dir, options: [:], operationQueue: Self.promiseQueue) { url, error in future.resolve(url, error) }`.
  4. The entry is `.promised(displayName: receiver.fileNames.first, deliver: { try await future.value })`. `fileNames` may be empty at this point; `AudioImport` then shows "Incoming file" until delivery.

`promiseQueue` is a dedicated serial `OperationQueue` (`qualityOfService = .userInitiated`).

A receiver that delivers several files contributes only its first. The others are deleted with the temp dir. This is an accepted limitation; Voice Memos and Photos promise one file per item.

### 2.6 Installation and placement

`WindowDropTargetInstaller: NSViewRepresentable` creates a `WindowDropView` and wires it to `model`, `isEnabled` and `onDrop`. Candidate placements, tried in order during the Phase 5 spike. The first that passes the §6 checklist wins:

1. **P1 (preferred):** the installer *is* the drop view, applied as the top-most layer of the shell root: `.overlay { WindowDropTargetInstaller(...).ignoresSafeArea() }` on the `Group` in `AppShellView.body`. No `.allowsHitTesting(false)`; the NSView's own `hitTest` filter keeps clicks flowing. SwiftUI keeps an `.overlay` representable above its siblings.
2. **P2:** the installer is a zero-size background view. In `viewDidMoveToWindow` it adds the `WindowDropView` as the last subview of `window.contentView` (pinned to its bounds with autoresizing). It re-raises the view in `layout()` if SwiftUI re-ordered subviews, and removes it in `dismantleNSView`.
3. **P3 (degraded fallback):** SwiftUI `.onDrop(of: [.fileURL], delegate:)` on the shell root. Hover state becomes `.supported(count: providers.count)` (no type knowledge while hovering, so no mixed or unsupported states). On drop, load the URLs, classify, skip unsupported, and do nothing if none are supported. No promise support. **Only use this if P1 and P2 both fail; record the outcome in the phase plan.**

Don't add subviews to the window's theme frame (AppKit logs an unsupported-subview warning). The toolbar strip lives in the titlebar container above the content view, so drops over the toolbar are **best-effort**: they work if the chosen placement catches them, and otherwise the overlay appears once the cursor reaches the content area.

---

## 3. Drop overlay view (`DropOverlayView.swift`)

```swift
public struct DropOverlayView: View {
    let model: DropTargetModel
    public var body: some View   // ZStack per ui_design §2; renders nothing when state == nil
}
```

- Applied as `.overlay { DropOverlayView(model: …).ignoresSafeArea().allowsHitTesting(false) }` on the shell root, **below** the P1 drop-target overlay in modifier order, so the drop view stays topmost.
- Visibility animation: `.animation(.easeOut(duration: 0.14), value: model.state == nil)` with `.transition(.opacity)`.
- Accessibility announcement when the state flips from nil to non-nil (`ui_design.md` §3.4).

---

## 4. Import screen

### 4.1 `ImportViewModel`

```swift
@MainActor @Observable
public final class ImportViewModel {
    public init(core: AppCore, revealInFinder: @escaping @MainActor (URL) -> Void = ImportViewModel.liveReveal)

    public var header: ImportHeaderCopy      // ImportHeaderCopy.make(items:run:runPosition:)
    public var rows: [ImportRowModel]

    public func goToMeeting(_ meetingID: UUID)   // core.select(meetingID)
    public func showInFinder(_ rowID: UUID)
}

public struct ImportRowModel: Identifiable, Equatable {
    public enum Icon { case sage, neutral, failed }
    public enum Trailing: Equatable { case waiting, receiving, converting, goToMeeting(UUID), deleted, showInFinder, none }
    public let id: UUID
    public let name: String
    public let secondLine: String        // date text, " " placeholder, or failure message
    public let secondLineIsError: Bool
    public let icon: Icon
    public let trailing: Trailing
}
```

- Row mapping, from `core.audioImport.items`:
  - `.receiving` → neutral, `.receiving`.
  - `.waiting` → neutral, `.waiting`.
  - `.converting` → sage, `.converting`.
  - `.done(id)` → sage, and `.goToMeeting(id)` if `core.summaries` contains `id`, else `.deleted`.
  - `.failed(f)` → failed, `.showInFinder`, `secondLine = f.message`, `secondLineIsError = true`.
  - Date text: `TimeFormatting.dateAndTime(date)` when `meetingDate` is set, else `" "`.
- **Show in Finder:** if `sourceURL` exists on disk → `NSWorkspace.shared.activateFileViewerSelecting([url])`. Else walk up `deletingLastPathComponent()` until a directory exists and `NSWorkspace.shared.open(dir)`. A failed row gets `.showInFinder` only when it has a `sourceURL`. A promise that failed before delivery has none, so its trailing is `.none` (empty).
- The shell creates one stable `ImportViewModel` (like `homeViewModel`).

### 4.2 `ImportView`

A straight translation of `ui_design.md` §3: `ScrollView` → centered column → header → card of `ImportRowView`s. `ImportRowView` renders an `ImportRowModel`. Buttons use `BezelButtonStyle`.

---

## 5. Shell and App wiring

### 5.1 `AppShellViewModel`

- New members: `public let importViewModel: ImportViewModel`, `public let dropTarget = DropTargetModel()`.
- Derived: `var hasImportSession: Bool { core.audioImport.hasSession }`, `var isImportConverting: Bool { core.audioImport.isConverting }`.
- Methods: `func showImport() { core.showImport() }`, `func importFiles(_ entries: [ImportEntry]) { core.importFiles(entries) }`.
- Import-panel passthroughs: `importPanelRequested`, `consumeImportPanelRequest()`.

### 5.2 `AppShellView`

- `DetailContentView`: `case .importing: ImportView(viewModel: viewModel.importViewModel).background(Tokens.contentBackground)`.
- Sidebar footer: `Divider` → `if viewModel.hasImportSession { importedRow }` → `settingsRow`. `importedRow` per `ui_design.md` §4.
- Root modifiers on the outer `Group`, applied after the existing ones:
  ```swift
  .overlay { DropOverlayView(model: viewModel.dropTarget).ignoresSafeArea().allowsHitTesting(false) }
  .overlay { WindowDropTargetInstaller(model: viewModel.dropTarget,
                                       isEnabled: { !viewModel.showOnboarding },
                                       onDrop: { viewModel.importFiles($0) }).ignoresSafeArea() }   // P1
  .fileImporter(isPresented: $showImportPanel,
                allowedContentTypes: ImportFileClassifier.allowedContentTypes,
                allowsMultipleSelection: true) { result in
      if case let .success(urls) = result { viewModel.importFiles(urls.map(ImportEntry.file)) }
  }
  .fileDialogConfirmationLabel("Import")
  .onChange(of: viewModel.importPanelRequested) { _, requested in
      if requested { showImportPanel = true; viewModel.consumeImportPanelRequest() }
  }
  .onAppear { if viewModel.importPanelRequested { showImportPanel = true; viewModel.consumeImportPanelRequest() } }
  ```
  `@State private var showImportPanel = false`. Wrap the selected URLs in `startAccessingSecurityScopedResource()` while building the entries (harmless in the non-sandboxed app, and future-proof). Release them after `add` returns. A hardened-runtime, non-sandboxed app can read the files directly.

### 5.3 `App/Sources/BiscottiApp.swift`

Inside `.commands { … }`:

```swift
CommandGroup(replacing: .importExport) {
    Button("Import Audio File\u{2026}") {
        appDelegate.showMainWindow()
        appDelegate.core?.requestImportPanel()
    }
    .keyboardShortcut("i", modifiers: [.command, .shift])
    .disabled(appDelegate.launchState.shellViewModel?.showOnboarding ?? true)
}
```

`LaunchState` and `AppShellViewModel` are both `@Observable`, so the command's disabled state tracks onboarding. `requestImportPanel()` also no-ops during onboarding as a backstop. The shortcut is P3: if it conflicts or misbehaves, ship without it and add `// TODO: ⌘⇧I shortcut`.

---

## 6. Manual verification checklist (human, end of Phase 5)

Run on a Mac, in light and dark mode:

1. Drag 1 `.m4a` from Finder over each of: the sidebar, the Home body, the Meetings list, meeting detail (transcript, **notes editor**, summary), Settings, the Recording screen, the Import screen, and the toolbar strip (best-effort). Each shows "Drop to import" with the format line, and the cursor shows "+". Dropping lands on the Import screen.
2. Drag 3 supported files: "Drop to import 3 files".
3. Drag 3 supported + 2 PDFs: mixed title + "2 files are unsupported…". After the drop, only 3 rows appear.
4. Drag 1 PDF: neutral "Can't import this file", no "+" badge. The drop does nothing.
5. Drag text or a link from Safari: no overlay.
6. Drag a recording from **Voice Memos** and a video from **Photos**: the overlay shows, and the rows go "Receiving…" → "Converting…" → Go to Meeting.
7. With no drag in progress: clicks, scrolling, hover highlights, tooltips, context menus, text editing in the notes and title fields, and toolbar buttons all behave exactly as before.
8. Esc during a drag dismisses the overlay.
9. During onboarding: no overlay, the drop is refused, and the File menu item does nothing or is disabled.
10. File > Import Audio File… (and ⌘⇧I): the sheet is filtered to audio/video and allows multi-select. Import lands on the Import screen.

The coding agent copies this checklist into the Phase 5 phase plan and records which placement (P1/P2/P3) passed.

---

## 7. Test plan (`Tests/ImportUITests`)

- **`DropOverlayStateTests`**
  - `classify` truth table: `[]` → nil; `[true]`; `[true, true, true]`; `[true, false]`; `[false]`; `[false, false]`.
  - `acceptsDrop` per case.
  - Every title, subtitle, format-line, skip-notice and neutral value, including singular/plural (`mixed(1, 1)`, `mixed(3, 2)`).
- **`PasteboardClassificationTests`**
  - Use a private `NSPasteboard(name: .init(UUID().uuidString))` with real `NSPasteboardItem`s: file-URL items for temp files (`.wav`, `.pdf`, a directory), plus a plain-string item → `supportedFlags == [true, false, false]` with the string ignored.
  - The promise branch can be exercised with a synthetic `DraggedItemDescriptor` list.
- **`ImportViewModelTests`** (`CoreFixture` + `FakeAudioConverter`)
  - Row mapping for each status.
  - `done` with the meeting deleted → `.deleted`.
  - The date text format.
  - `goToMeeting` routes to `.meetings` with that selection.
  - `showInFinder` with an existing file → the reveal closure gets the file. With a missing file → it gets the nearest existing parent.
  - The header passes through `ImportHeaderCopy`.
- **`AppShellUITests`**: the Imported-row visibility and selection (architecture §9).
