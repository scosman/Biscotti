---
status: complete
---

# Component: UI Modules (Stage C)

## Purpose and Scope

This document designs the **view models and view structure** for every Stage C screen: three new
modules (`HomeUI`, `SearchUI`, `SettingsUI`, `OnboardingUI`, `MenuBarUI`), plus the rich-slice
extensions to `MeetingDetailUI`, `MeetingListUI`, and `AppShellUI`. Together they deliver the full V1
in-window browsing experience (home, library, search, rich meeting detail, settings, onboarding) and
the menu-bar surface.

Each screen is an uber-native SwiftUI view paired with a `@MainActor @Observable` view model. View
models are the unit-testable surface -- they read `AppCore`, `DataStore` DTOs, and service DTOs
(`CalendarEvent`, `CalendarInfo`, etc.), expose derived state and formatting helpers, and forward
actions to `AppCore`. Views are previewable wrappers that bind the view model and compose
`DesignSystem` components. No business logic, no live `@Model`, no `EKEvent` in any view or view
model.

**Not this component's job:**

- Business logic, coordination, or persistence. `AppCore` owns recording/transcription/detection
  orchestration and route management. `DataStore` owns persistence. `CalendarService`,
  `VocabularyService`, `NotificationService` own their domains. VMs call through `AppCore` or read
  DTOs; they never call `DataStore` write methods or EventKit directly.
- The `RecordingUI` module is unchanged from Stage B and is not covered here.
- DesignSystem component internals (CalendarContextBlock, AudioTransport, etc.) are listed under
  shared conventions but designed only to the level of their props/API, not their internal view
  trees.

---

## Shared Conventions

These match Stage B exactly (`stage_b_mvp/architecture.md` section 9) and extend them for Stage C.

### View-model pattern

Every screen has one `@MainActor @Observable final class` view model. The VM is constructed with
`AppCore` (and occasionally a service or store reference reachable through `AppCore`). It exposes:

- **Read-only projected state**: computed properties that derive display-ready values from
  `AppCore`/service observable properties. SwiftUI observes these through `@Observable` tracking.
- **Actions**: `func` methods (often `async`) that delegate to `AppCore` methods. The VM never
  performs multi-step coordination itself.
- **Pure formatting helpers**: `static` or instance methods for date/time/duration formatting,
  grouping, truncation -- testable without any service dependency.

VMs do NOT:
- Hold mutable `@Model` objects or `EKEvent` references.
- Import framework-specific modules (`EventKit`, `AVFoundation`, `UserNotifications`).
  AVFoundation is the one exception -- `MeetingDetailViewModel` uses `AVAudioPlayer` behind a
  protocol seam for playback.
- Perform writes to `DataStore` directly (always via `AppCore` or a service method on `AppCore`).

### How VMs get data

VMs are constructed with `AppCore`. They read:

- `AppCore.route`, `AppCore.runState`, `AppCore.upcoming`, `AppCore.summaries`,
  `AppCore.searchReturnRoute` -- observable published state.
- `AppCore.calendar` (`CalendarService`) -- `.auth`, `.upcoming`, `.calendars()`, `.event(forKey:)`.
- `AppCore.store` -- async DTO queries (`meetingDetail(id:)`, `calendarContext(meetingID:)`,
  `transcriptVersions(meetingID:)`, `transcript(id:)`, `audioFileRefs(meetingID:)`,
  `searchHits(_:limit:)`, `settings()`).
- `AppCore.permissions` -- `.microphone`, `.systemAudio`, `.calendar`, `.notifications`.
- `AppCore.vocabulary` -- `appWide()`, `setAppWide(_:)`.
- `AppCore.transcription` -- `jobs[meetingID]` for live status.

### Routing

`AppCore` owns `route: Route` (the extended enum: `.home`, `.recording`, `.meeting(UUID)`,
`.event(String)`, `.search`, `.settings`, `.onboarding`). VMs never set `route` directly; they call
`AppCore` navigation methods (`showHome()`, `presentSearch()`, `dismissSearch()`, `showSettings()`,
`showOnboardingReplay()`, `select(_:)`, `selectEvent(_:)`). `AppShellViewModel` reads `core.route`
to switch the detail pane.

### Empty and error states

Every list/content VM exposes an enum or boolean for its empty state so the view can show the
appropriate message:

- "No recordings yet" (past list empty).
- "Connect your calendar to see upcoming meetings" (calendar denied/not-determined).
- "No meetings coming up" (calendar authorized but no upcoming meeting-like events).
- "No meetings match '{query}'" (search, no results).
- Audio transport disabled: "Audio files not available" (when `AudioFileRef.isPresent == false`).

Error states for processing/failed transcription are unchanged from Stage B
(`MeetingDetailState`).

### DesignSystem reuse and new components

**Reused from Stage B:** `Banner`, `StatusRow`, `RecordButton`, `TranscriptSegmentRow`, `Tokens`.

**New DesignSystem components** (from `ui_design.md` section 10). Each is a simple SwiftUI view with
value-type inputs (no VM):

| Component | Props | Notes |
|---|---|---|
| `CalendarContextBlock` | `platform: String?`, `conferenceURL: URL?`, `calendarTitle: String?`, `calendarColorHex: String?`, `organizer: PersonData?`, `attendees: [PersonData]`, `isStale: Bool`, `onJoin: (() -> Void)?`, `onChange: (() -> Void)?` | Section with join link, calendar badge, attendee chips, Change button. |
| `AudioTransport` | `isPlaying: Bool`, `currentTime: TimeInterval`, `duration: TimeInterval`, `isDisabled: Bool`, `onPlayPause: () -> Void`, `onSeek: (TimeInterval) -> Void` | Play/pause + Slider scrubber + time labels. Disabled state shows explanation. |
| `VersionPicker` | `versions: [TranscriptVersionData]`, `selectedID: UUID`, `onSelect: (UUID) -> Void` | macOS `Menu`-button dropdown listing versions by date + method + preferred badge. |
| `VocabularyEditor` | `terms: Binding<[String]>` | Token list with add/remove/edit. |
| `PermissionRow` | `label: String`, `state: PermissionState`, `onFix: (() -> Void)?` | Status icon + label + "Open Settings" button when denied. |
| `WizardStep` | `title: String`, `explanation: String`, `content: AnyView`, `onSkip: (() -> Void)?`, `onContinue: () -> Void` | Standard page layout for onboarding steps: title, why-text, action area, Skip/Continue. |
| `UpcomingEventRow` | `title: String`, `timeText: String`, `platformBadge: String?` | Compact row for sidebar/home/menu-bar upcoming lists. |
| `PastMeetingRow` | `title: String`, `dateText: String`, `isSelected: Bool` | Sidebar past-meeting row (replaces inline `meetingRow` in Stage B MeetingListView). |

Each new component ships a `#Preview`.

---

## Per Module

### AppShellUI (extended)

#### Changes from Stage B

The Stage B `AppShellView` is a `NavigationSplitView` with a sidebar (Record + recording indicator +
PAST list) and a detail pane routed by `Route`. Stage C grows the sidebar into a full navigation
surface (Home / Recording / Upcoming / Past grouped / Settings) and the detail pane to route all new
screens. The toolbar gains a search field that triggers `.search` takeover. First launch shows the
onboarding gate.

#### AppShellViewModel additions

```
Existing (unchanged):
  - core: AppCore
  - meetingListViewModel: MeetingListViewModel (now extended -- see MeetingListUI below)
  - recordingViewModel: RecordingViewModel
  - meetingDetailViewModel(for:) -> MeetingDetailViewModel (extended)
  - route: Route (computed from core.route)
  - recordButtonDisabled: Bool
  - showRecordingIndicator: Bool
  - recordingElapsedText: String
  - startRecording() async
  - showRecording()
  - onLaunch() async

New state:
  - searchText: String              // bound to the toolbar search field; non-empty triggers .search
  - homeViewModel: HomeViewModel    // created once, cached
  - searchViewModel: SearchViewModel  // created once, cached
  - settingsViewModel: SettingsViewModel  // created once, cached
  - onboardingViewModel: OnboardingViewModel  // created once, cached

New computed:
  - showOnboarding: Bool            // core.route == .onboarding
  - upcomingEvents: [CalendarEvent] // core.upcoming (for sidebar Upcoming section)
  - hasCalendarAccess: Bool         // core.calendar.auth == .authorized
  - selectedSidebarItem: SidebarItem?  // derived from route for sidebar highlight

New actions:
  - showHome()                      // core.showHome()
  - showSettings()                  // core.showSettings()
  - selectEvent(_ key: String)      // core.route = .event(key)  -- via AppCore method
  - onSearchTextChange(_ text: String)  // if non-empty: core.presentSearch(), update searchVM query
                                         // if empty: core.dismissSearch()
  - clearSearch()                   // searchText = "", core.dismissSearch()
```

**`SidebarItem`** is a private enum `{home, recording, upcoming(String), past(UUID), settings}` used
only for highlight tracking, not exposed outside the module.

#### View structure

```
AppShellView
  NavigationSplitView
    sidebar:
      VStack
        RecordButton (disabled when recording/runState != .idle)
        if showRecordingIndicator: recordingIndicator button -> showRecording()
        Divider
        // Home row (always visible)
        Button "Home" -> showHome(), highlight when route == .home
        Divider
        // Upcoming section (hidden when !hasCalendarAccess or upcomingEvents.isEmpty)
        if hasCalendarAccess && !upcomingEvents.isEmpty:
          Text("UPCOMING")
          ForEach upcomingEvents: UpcomingEventRow -> selectEvent(key)
        // Past section
        Text("PAST")
        ScrollView: MeetingListView(viewModel: meetingListViewModel)
        Spacer
        Divider
        // Settings (pinned bottom)
        Button "Settings" -> showSettings(), highlight when route == .settings
      .frame(minWidth: 180, idealWidth: 220)
    detail:
      switch route:
        .home -> HomeView(viewModel: homeViewModel)
        .recording -> RecordingView(viewModel: recordingViewModel)
        .meeting(id) -> MeetingDetailView(viewModel: meetingDetailViewModel(for: id)).id(id)
        .event(key) -> EventPreviewView (calendar context + Record button; part of MeetingDetailUI)
        .search -> SearchView(viewModel: searchViewModel)
        .settings -> SettingsView(viewModel: settingsViewModel)
        .onboarding -> OnboardingView(viewModel: onboardingViewModel)
  .searchable(text: $searchText, placement: .toolbar)
  .onChange(of: searchText) { onSearchTextChange($1) }
  .task { await onLaunch() }
```

The `.searchable` modifier binds to the toolbar search field. Typing a non-empty query routes to
`.search` and the search view model receives the query. The SwiftUI `.searchable` provides the
standard magnifying-glass + clear affordance; the "Back" control in the search results is rendered
by `SearchView` and calls `clearSearch()`.

---

### HomeUI (new)

#### HomeViewModel

```swift
@MainActor @Observable
public final class HomeViewModel {
    private let core: AppCore

    // MARK: - State (all derived from core)

    /// The upcoming meeting-like events to show as a preview list.
    /// Reads from core.upcoming (CalendarEvent DTOs from CalendarService).
    public var upcomingPreview: [CalendarEvent] {
        Array(core.upcoming.prefix(3))     // show at most 3 on the home screen
    }

    /// Whether the Start Recording button should be disabled.
    public var startDisabled: Bool {
        core.runState != .idle             // disabled while recording or detected-pending
    }

    /// Calendar access state for the empty/connect state.
    public var calendarAccess: CalendarAuthStatus {
        core.calendar.auth
    }

    /// Whether to show the "no upcoming" message (authorized but empty).
    public var showNoUpcoming: Bool {
        calendarAccess == .authorized && upcomingPreview.isEmpty
    }

    /// Whether to show the "connect calendar" message (not authorized).
    public var showConnectCalendar: Bool {
        calendarAccess != .authorized
    }

    // MARK: - Actions

    public func startRecording() async {
        await core.startRecording()
    }

    /// Deep-link to calendar permission (used from the "connect" empty state).
    public func requestCalendarAccess() async {
        _ = await core.calendar.requestAccess()
    }

    /// Select an upcoming event to preview its detail.
    public func selectEvent(_ key: String) {
        core.selectEvent(key)              // routes to .event(key)
    }

    // MARK: - Formatting

    /// Formats a CalendarEvent's start time as relative ("in 12m") or absolute ("2:30 PM").
    public static func timeText(for event: CalendarEvent, relativeTo now: Date = Date()) -> String
}
```

#### View structure

```
HomeView
  VStack (centered)
    Spacer
    Text("Welcome to Biscotti") .font(.title2)
    Text("Private, on-device meeting transcripts") .font(metadataFont) .secondary
    Spacer(minLength: spacingLG)
    RecordButton(isDisabled: startDisabled) { startRecording() }  // prominent, centered
    Spacer(minLength: spacingLG)
    // Upcoming section
    if showConnectCalendar:
      VStack: Text("Connect your calendar...") + Button("Allow Calendar Access") { requestCalendarAccess() }
    else if showNoUpcoming:
      Text("No meetings coming up.")
    else:
      Text("Upcoming") .sectionHeaderFont
      ForEach upcomingPreview: UpcomingEventRow(title, timeText, platformBadge) -> selectEvent(key)
    Spacer
  .frame(maxWidth: .infinity, maxHeight: .infinity)
```

---

### MeetingListUI (extended)

#### Changes from Stage B

Stage B shows a flat `ForEach` over `core.summaries` (newest first). Stage C replaces this with a
**Past list grouped by effective date** (Today / Yesterday / This Week / Earlier) and optionally an
**Upcoming list** from `CalendarEvent` DTOs. The Upcoming list moves into the sidebar (AppShellUI)
rather than being owned by MeetingListUI, so MeetingListUI only handles the Past grouped list.

#### MeetingListViewModel additions

```
Existing (unchanged):
  - core: AppCore
  - meetings: [MeetingSummary]       // core.summaries
  - selectedMeetingID: UUID?          // from core.route
  - select(_ meetingID: UUID)

New computed:
  - groupedMeetings: [MeetingGroup]  // grouped + sorted; pure computed from meetings

New types:
  public struct MeetingGroup: Identifiable {
      public let id: String           // "today", "yesterday", "thisWeek", "earlier"
      public let title: String        // "Today", "Yesterday", "This Week", "Earlier"
      public let meetings: [MeetingSummary]
  }

New static helpers:
  - static func groupByEffectiveDate(
        _ meetings: [MeetingSummary],
        relativeTo now: Date = Date(),
        calendar: Foundation.Calendar = .autoupdatingCurrent
    ) -> [MeetingGroup]
    // Pure function: partitions meetings into Today/Yesterday/This Week/Earlier
    // by comparing meeting.date against now. Each group sorted newest-first.
    // Empty groups omitted.
```

The grouping logic is a pure static function so it is directly unit-testable without any service
dependency. The calendar parameter allows deterministic tests with a fixed reference date.

#### View structure (updated)

```
MeetingListView
  Group
    if groupedMeetings.isEmpty:
      Text("No recordings yet") .metadataFont .secondary
    else:
      ForEach groupedMeetings { group in
        Section(header: Text(group.title) .sectionHeaderFont .secondary) {
          ForEach group.meetings { meeting in
            PastMeetingRow(title: meeting.title, dateText: relativeDate(meeting.date),
                           isSelected: selectedMeetingID == meeting.id)
              .onTapGesture { select(meeting.id) }
          }
        }
      }
```

---

### SearchUI (new)

#### SearchViewModel

```swift
@MainActor @Observable
public final class SearchViewModel {
    private let core: AppCore

    // MARK: - State

    /// The current search query, set by AppShellViewModel when the toolbar text changes.
    public var query: String = ""

    /// The search results (ranked, from DataStore.searchHits).
    public private(set) var results: [SearchHit] = []

    /// Whether a search is in progress.
    public private(set) var isSearching: Bool = false

    // MARK: - Derived

    /// Whether to show the "no results" empty state.
    public var showNoResults: Bool {
        !query.isEmpty && results.isEmpty && !isSearching
    }

    /// The message for the no-results state.
    public var noResultsMessage: String {
        "No meetings match '\(query)'."
    }

    // MARK: - Actions

    /// Called when the query changes. Debounces and runs the search.
    /// The debounce is ~300ms; implemented via a private Task that cancels
    /// the prior search on each keystroke.
    public func updateQuery(_ newQuery: String) {
        query = newQuery
        debounceAndSearch()
    }

    /// Called when the user taps a search result. Opens the meeting detail.
    public func selectResult(_ meetingID: UUID) {
        core.select(meetingID)
    }

    /// Called when the user taps Back. Restores the pre-search route.
    public func dismiss() {
        core.dismissSearch()
    }

    // MARK: - Private

    private var searchTask: Task<Void, Never>?

    private func debounceAndSearch() {
        searchTask?.cancel()
        guard !query.isEmpty else {
            results = []
            return
        }
        searchTask = Task { @MainActor [weak self, query] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self, self.query == query else { return }
            self.isSearching = true
            do {
                self.results = try await self.core.store.searchHits(query, limit: 50)
            } catch {
                self.results = []
            }
            self.isSearching = false
        }
    }

    // MARK: - Formatting

    /// A human-readable description of which fields matched, e.g. "title, transcript".
    public static func matchedFieldsText(_ fields: [SearchField]) -> String {
        fields.map { field in
            switch field {
            case .title: "title"
            case .people: "people"
            case .transcript: "transcript"
            }
        }.joined(separator: ", ")
    }
}
```

#### View structure

```
SearchView
  VStack(alignment: .leading)
    HStack
      Button("< Back") { dismiss() }
      Spacer
    Divider
    if isSearching:
      ProgressView()
    else if showNoResults:
      Text(noResultsMessage) .metadataFont .secondary .padding
    else:
      ScrollView
        LazyVStack(alignment: .leading)
          ForEach results { hit in
            Button { selectResult(hit.id) } label:
              VStack(alignment: .leading, spacing: 2)
                HStack
                  Text(hit.title) .font(.body) .lineLimit(1)
                  Spacer
                  Text(MeetingDetailViewModel.formatDate(hit.date)) .metadataFont .secondary
                Text("matches: " + matchedFieldsText(hit.matchedFields)) .font(.caption) .secondary
            .buttonStyle(.plain) .padding
          }
  .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
```

---

### MeetingDetailUI (extended, rich slice)

#### Changes from Stage B

Stage B `MeetingDetailViewModel` loads `MeetingDetailData` (title, date, duration, hasAudio,
preferredTranscript) and observes `transcription.jobs[meetingID]` for live status. It surfaces three
display states: `.processing`, `.transcript`, `.failed`.

Stage C extends the VM to load the full rich detail: calendar context, notes, transcript versions,
audio file refs for playback. It adds version switching, notes editing with autosave, audio playback
(with a protocol seam), calendar context display, and association correction. The three processing/
failed states are preserved as-is.

#### MeetingDetailData extensions (DataStore DTO, for reference)

Stage C extends `MeetingDetailData` with:
- `calendar: CalendarContextData?` -- the snapshot-based calendar context.
- `notes: String` -- the meeting's editable notes.
- `versions: [TranscriptVersionData]` -- all transcript versions for this meeting.

#### AudioPlaybackProviding (seam for testability)

```swift
/// Seam over AVAudioPlayer so the VM is testable without real audio.
public protocol AudioPlaybackProviding: AnyObject {
    var isPlaying: Bool { get }
    var currentTime: TimeInterval { get set }
    var duration: TimeInterval { get }
    func play()
    func pause()
    func load(url: URL) throws
}
```

Production implementation wraps `AVAudioPlayer`. Tests inject a fake.

#### MeetingDetailViewModel additions

```
Existing (unchanged):
  - core: AppCore
  - meetingID: UUID
  - detail: MeetingDetailData?
  - isLoading: Bool
  - displayState: MeetingDetailState (extended -- see below)
  - currentJobStatus: JobStatus?
  - canReTranscribe: Bool
  - title: String
  - formattedDate: String
  - formattedDuration: String?
  - load() async
  - onJobStatusChange(_ newStatus: JobStatus?) async
  - reTranscribe() async
  - retry() async

New state:
  - calendarContext: CalendarContextData?    // loaded from store
  - notes: String = ""                       // two-way; autosaved
  - versions: [TranscriptVersionData] = []   // all transcript versions
  - selectedVersionID: UUID?                 // which version is displayed; nil = preferred
  - selectedTranscript: TranscriptData?      // the loaded transcript for selectedVersionID
  - audioPlayer: (any AudioPlaybackProviding)?  // nil if no audio
  - isAudioAvailable: Bool                   // from audioFileRefs.present
  - isPlaying: Bool                          // audioPlayer?.isPlaying ?? false
  - playbackCurrentTime: TimeInterval        // audioPlayer?.currentTime ?? 0
  - playbackDuration: TimeInterval           // audioPlayer?.duration ?? 0
  - notesAutosaveTask: Task<Void, Never>?    // debounced autosave
  - showEventPicker: Bool = false            // for association correction sheet

New computed:
  - hasCalendarContext: Bool                 // calendarContext != nil
  - displayedTranscript: TranscriptData?    // selectedTranscript ?? detail?.preferredTranscript
  - canPlay: Bool                           // isAudioAvailable && audioPlayer != nil
  - activeVersionID: UUID?                  // selectedVersionID ?? detail?.preferredTranscript?.id
  - showLinkEventPrompt: Bool               // !hasCalendarContext (quiet "Link a calendar event...")

New actions:
  - selectVersion(_ versionID: UUID) async
    // Sets selectedVersionID, loads transcript(id:) from store
  - updateNotes(_ text: String)
    // Sets notes, debounces 1s, then calls core.store.setNotes(text, for: meetingID)
  - playPause()
    // Toggles audioPlayer play/pause
  - seek(to time: TimeInterval)
    // Sets audioPlayer.currentTime
  - presentAssociationCorrection()
    // Sets showEventPicker = true
  - correctAssociation(eventKey: String?) async
    // Calls core.correctAssociation(meetingID:, eventKey:) -> reloads calendarContext
    // After correction, surfaces a prompt to re-transcribe (vocab may differ)
  - removeAssociation() async
    // correctAssociation(eventKey: nil)
```

**`load()` extension:** After loading `detail`, also loads:
- `core.store.calendarContext(meetingID:)` into `calendarContext`.
- `core.store.transcriptVersions(meetingID:)` into `versions`.
- `core.store.audioFileRefs(meetingID:)` -- if present, initializes `audioPlayer` via the seam
  (`load(url:)` with the mic file URL; system audio mixed in if available -- or just mic for V1).
- `detail.notes` into `notes`.

**`displayState` extension:** The `.transcript(MeetingDetailData)` case is unchanged. The view now
also reads `displayedTranscript` (which may differ from `detail?.preferredTranscript` when a
non-preferred version is selected via the picker). The view conditionally shows the calendar context
block, notes section, and audio transport above/below the transcript based on VM state.

#### View structure (extended)

```
MeetingDetailView
  ScrollView
    VStack(alignment: .leading, spacing: 0)
      // Header (extended)
      HStack
        Text(title) .meetingTitleFont
        Spacer
        if versions.count > 1:
          VersionPicker(versions: versions, selectedID: activeVersionID) { selectVersion($0) }
        if canReTranscribe:
          Button("Re-transcribe") { reTranscribe() }
      HStack: formattedDate + formattedDuration

      Divider

      // Calendar context block (new)
      if hasCalendarContext:
        CalendarContextBlock(calendarContext, onJoin: { openURL }, onChange: { presentAssociationCorrection() })
      else if showLinkEventPrompt:
        Button("Link a calendar event...") { presentAssociationCorrection() } .font(.caption)

      // Audio transport (new)
      AudioTransport(isPlaying, playbackCurrentTime, playbackDuration, isDisabled: !canPlay,
                     onPlayPause: { playPause() }, onSeek: { seek(to: $0) })

      Divider

      // Notes (new)
      Text("Notes") .sectionHeaderFont
      TextEditor(text: binding to notes) { updateNotes($0) }
        .frame(minHeight: 60)

      Divider

      // Transcript (unchanged state content, but reads displayedTranscript)
      stateContent (processing / transcript using displayedTranscript / failed)

  .task { await load() }
  .onChange(of: currentJobStatus) { onJobStatusChange($1) }
  .sheet(isPresented: $showEventPicker) { EventPickerSheet(...) }
```

**EventPickerSheet** is a small internal view (not a separate module) that lists meeting-like
`CalendarEvent`s from `core.calendar.upcoming` (plus a broader search window) and a "Remove
association" option. Selecting calls `correctAssociation(eventKey:)` or `removeAssociation()`.

---

### SettingsUI (new)

#### SettingsViewModel

```swift
@MainActor @Observable
public final class SettingsViewModel {
    private let core: AppCore

    // MARK: - General

    /// Launch at login toggle state. Read from settings; writes via AppCore.
    public var launchAtLogin: Bool {
        get { settings?.launchAtLogin ?? true }
        set { Task { await toggleLaunchAtLogin(newValue) } }
    }

    // MARK: - Calendars

    /// All calendars grouped by source, for the include/exclude toggles.
    public private(set) var calendarGroups: [CalendarGroup] = []

    /// The set of enabled calendar IDs. nil = all enabled.
    public private(set) var enabledCalendarIDs: Set<String>?

    public struct CalendarGroup: Identifiable {
        public let id: String        // source title
        public let sourceTitle: String
        public let calendars: [CalendarInfo]
    }

    /// Whether a calendar is enabled (checked).
    public func isCalendarEnabled(_ calendarID: String) -> Bool {
        guard let enabled = enabledCalendarIDs else { return true }  // nil = all
        return enabled.contains(calendarID)
    }

    /// Toggle a calendar on/off. Persists to settings.
    public func toggleCalendar(_ calendarID: String) async

    // MARK: - Custom Vocabulary

    /// The app-wide custom vocabulary terms.
    public var vocabularyTerms: [String] = []

    /// Add a new term.
    public func addTerm(_ term: String) async
    /// Remove a term at the given index.
    public func removeTerm(at index: Int) async
    /// Update a term at the given index.
    public func updateTerm(at index: Int, to newValue: String) async

    // MARK: - Permissions

    /// Permission states for each kind.
    public var microphoneState: PermissionState { core.permissions.microphone }
    public var systemAudioState: PermissionState { core.permissions.systemAudio }
    public var calendarState: PermissionState { core.permissions.calendar }
    public var notificationsState: PermissionState { core.permissions.notifications }

    /// Open System Settings to the appropriate privacy pane.
    public func openPermissionSettings(for kind: PermissionKind)

    // MARK: - Navigation

    /// Re-run onboarding from Settings.
    public func rerunOnboarding() {
        core.showOnboardingReplay()
    }

    // MARK: - Lifecycle

    /// Load initial data (calendars, vocabulary, settings).
    public func load() async

    // MARK: - Private

    private var settings: AppSettingsData?

    private func toggleLaunchAtLogin(_ enabled: Bool) async {
        // core.setLaunchAtLogin(enabled)  -- AppCore wraps SMAppService + settings update
    }
}
```

**`load()` flow:**
1. `settings = try await core.store.settings()` -- reads launchAtLogin, enabledCalendarIDs.
2. `let infos = await core.calendar.calendars()` -- all calendars.
3. Group `infos` by `sourceTitle` into `calendarGroups`.
4. `vocabularyTerms = await core.vocabulary.appWide()`.

**`toggleCalendar` flow:**
1. Compute the new `enabledCalendarIDs` set.
2. `core.store.updateSettings { $0.enabledCalendarIDs = newSet }`.
3. `core.calendar.refreshUpcoming(window:)` -- so the upcoming list reflects the change.

#### View structure

```
SettingsView
  ScrollView
    Form
      // General
      Section("General")
        Toggle("Launch at login", isOn: $launchAtLogin)

      // Calendars
      Section("Calendars")
        if calendarState == .authorized:
          ForEach calendarGroups { group in
            Section(header: Text(group.sourceTitle))
              ForEach group.calendars { cal in
                Toggle(cal.title, isOn: binding for isCalendarEnabled/toggleCalendar)
                  // leading: circle with cal.colorHex
              }
          }
        else:
          Text("Calendar access not granted.")
          PermissionRow(label: "Calendar", state: calendarState) { openPermissionSettings(.calendar) }

      // Custom Vocabulary
      Section("Custom Vocabulary")
        VocabularyEditor(terms: $vocabularyTerms)  // add/remove/edit; onChange persists

      // Permissions
      Section("Permissions")
        PermissionRow(label: "Microphone", state: microphoneState) { openPermissionSettings(.microphone) }
        PermissionRow(label: "System Audio", state: systemAudioState) { openPermissionSettings(.systemAudio) }
        PermissionRow(label: "Calendar", state: calendarState) { openPermissionSettings(.calendar) }
        PermissionRow(label: "Notifications", state: notificationsState) { openPermissionSettings(.notifications) }

      // Advanced
      Section
        Button("Re-run Onboarding...") { rerunOnboarding() }

  .task { await load() }
```

---

### OnboardingUI (new)

#### OnboardingViewModel

The onboarding wizard is a linear step state machine. Each step has a type, and the VM tracks which
step the user is on, the result of each permission request, and model download progress.

```swift
@MainActor @Observable
public final class OnboardingViewModel {
    private let core: AppCore

    // MARK: - Step state machine

    public enum Step: Int, CaseIterable, Sendable {
        case welcome = 0
        case microphone
        case systemAudio
        case calendar
        case calendarSelection    // shown only after calendar access granted
        case notifications
        case modelDownload
        case done
    }

    /// The current step.
    public private(set) var currentStep: Step = .welcome

    /// Total number of steps (for the progress indicator). Calendar selection
    /// is conditional so the indicator shows 7 dots (welcome through done,
    /// treating calendarSelection as part of the calendar step).
    public var totalSteps: Int { 7 }

    /// The step index for the progress indicator (0-based, maps calendarSelection
    /// to the same dot as calendar).
    public var progressIndex: Int {
        switch currentStep {
        case .welcome: 0
        case .microphone: 1
        case .systemAudio: 2
        case .calendar, .calendarSelection: 3
        case .notifications: 4
        case .modelDownload: 5
        case .done: 6
        }
    }

    // MARK: - Per-step state

    /// Permission results (updated after each request).
    public private(set) var microphoneResult: PermissionState = .notDetermined
    public private(set) var systemAudioResult: PermissionState = .notDetermined
    public private(set) var calendarResult: CalendarAuthStatus = .notDetermined
    public private(set) var notificationsGranted: Bool = false

    /// Calendar selection (reuses SettingsVM pattern).
    public private(set) var calendarGroups: [SettingsViewModel.CalendarGroup] = []
    public private(set) var enabledCalendarIDs: Set<String>?
    public func isCalendarEnabled(_ id: String) -> Bool { ... }
    public func toggleCalendar(_ id: String) async { ... }

    /// Model download state.
    public private(set) var downloadStatus: String?    // nil = not started, else engine status message
    public private(set) var isDownloading: Bool = false
    public private(set) var downloadComplete: Bool = false

    /// Disk space check for model download step.
    public private(set) var hasSufficientDisk: Bool = true
    public static let requiredDiskSpaceMB: Int = 2000  // ~2 GB for models

    // MARK: - Actions

    /// Advance to the next step. Called by Continue button.
    public func advance() async {
        switch currentStep {
        case .welcome:
            currentStep = .microphone
        case .microphone:
            currentStep = .systemAudio
        case .systemAudio:
            currentStep = .calendar
        case .calendar:
            if calendarResult == .authorized {
                // Load calendars and show selection
                calendarGroups = groupCalendars(await core.calendar.calendars())
                currentStep = .calendarSelection
            } else {
                currentStep = .notifications
            }
        case .calendarSelection:
            currentStep = .notifications
        case .notifications:
            checkDiskSpace()
            currentStep = .modelDownload
        case .modelDownload:
            currentStep = .done
        case .done:
            await completeOnboarding()
        }
    }

    /// Skip the current step (available on permission steps and model download).
    public func skip() async {
        // Same as advance but without requesting the permission / triggering download.
        await advance()
    }

    /// Request the permission for the current step.
    public func requestPermission() async {
        switch currentStep {
        case .microphone:
            let granted = await core.permissions.requestMicrophone()
            microphoneResult = granted ? .authorized : .denied
        case .systemAudio:
            // System audio permission is triggered by exercising capture.
            // The result is inferred. For onboarding, we request and read back.
            await core.requestSystemAudioPermission()
            systemAudioResult = core.permissions.systemAudio
        case .calendar:
            calendarResult = await core.calendar.requestAccess()
        case .notifications:
            notificationsGranted = await core.notifications.requestAuthorization()
        default:
            break
        }
    }

    /// Start the model download (on the model download step).
    public func startDownload() async {
        isDownloading = true
        downloadStatus = "Preparing..."
        do {
            try await core.transcription.ensureModelsReady { [weak self] message in
                Task { @MainActor in self?.downloadStatus = message }
            }
            downloadComplete = true
        } catch {
            downloadStatus = "Download failed. You can retry or skip."
        }
        isDownloading = false
    }

    /// Open System Settings for a denied permission.
    public func openSettings(for kind: PermissionKind) {
        NSWorkspace.shared.open(core.permissions.settingsURL(for: kind))
    }

    /// Complete onboarding: persist the flag and navigate to Home.
    public func completeOnboarding() async {
        await core.completeOnboarding()
    }

    // MARK: - Private

    private func checkDiskSpace() { ... }
    private func groupCalendars(_ infos: [CalendarInfo]) -> [SettingsViewModel.CalendarGroup] { ... }
}
```

**TranscriptionService API note:** The `ensureModelsReady` call used here requires
`TranscriptionService` to expose a method that wraps `engine.ensureModelsDownloaded(status:)` with
a progress callback. This is a small delta on `TranscriptionService` (currently the download is
triggered only inside `transcribe()`). It should be exposed as:
```swift
public func ensureModelsReady(status: @escaping @Sendable (String) -> Void) async throws
```

#### View structure

```
OnboardingView
  VStack
    // Step indicator
    HStack(spacing: 4)
      ForEach 0..<totalSteps { i in
        Circle(fill: i <= progressIndex ? .primary : .secondary.opacity(0.3))
          .frame(width: 8, height: 8)
      }

    Spacer

    // Step content (uses WizardStep scaffold)
    switch currentStep:
      .welcome:
        WizardStep(title: "Welcome to Biscotti",
                   explanation: "Private, on-device meeting transcripts. Nothing leaves your Mac.",
                   content: { EmptyView() },
                   onContinue: { advance() })

      .microphone:
        WizardStep(title: "Microphone access",
                   explanation: "Biscotti records your voice locally to transcribe your meetings.",
                   content: {
                     Button("Allow Microphone") { requestPermission() }
                     if microphoneResult == .denied:
                       Button("Open System Settings") { openSettings(for: .microphone) }
                   },
                   onSkip: { skip() }, onContinue: { advance() })

      .systemAudio:
        WizardStep(title: "System audio",
                   explanation: "Capture meeting audio from apps like Zoom and Teams.",
                   content: { similar pattern },
                   onSkip: { skip() }, onContinue: { advance() })

      .calendar:
        WizardStep(title: "Calendar access",
                   explanation: "See upcoming meetings and auto-link recordings to events.",
                   content: { Button + denial recovery },
                   onSkip: { skip() }, onContinue: { advance() })

      .calendarSelection:
        WizardStep(title: "Choose calendars",
                   explanation: "Select which calendars to monitor for meetings.",
                   content: {
                     ForEach calendarGroups -> toggles (same as Settings)
                   },
                   onContinue: { advance() })

      .notifications:
        WizardStep(title: "Notifications",
                   explanation: "Get notified when meetings start so you can record.",
                   content: { Button + denial recovery },
                   onSkip: { skip() }, onContinue: { advance() })

      .modelDownload:
        WizardStep(title: "Download speech model",
                   explanation: "A one-time download (~1.5 GB). Runs entirely on your Mac.",
                   content: {
                     if !hasSufficientDisk: Banner("Not enough disk space...", style: .warning)
                     else if downloadComplete: StatusRow("Ready", isProgress: false)
                     else if isDownloading: StatusRow("Downloading...", subtitle: downloadStatus)
                     else: Button("Download Now") { startDownload() }
                   },
                   onSkip: { skip() }, onContinue: { advance() })

      .done:
        VStack
          Text("You're all set!") .title2
          Text("Start recording your first meeting.")
          Button("Get Started") { completeOnboarding() } .borderedProminent
    Spacer
  .frame(maxWidth: .infinity, maxHeight: .infinity)
  .padding(spacingXL)
```

---

### MenuBarUI (new)

The `MenuBarUI` module provides a view model and view for the `MenuBarExtra` scene defined in the
app target. The app target owns the `MenuBarExtra` declaration; `MenuBarUI` provides the content
view and the label view.

#### MenuBarViewModel

```swift
@MainActor @Observable
public final class MenuBarViewModel {
    private let core: AppCore

    // MARK: - Icon state

    /// The icon/label state for the MenuBarExtra.
    public enum IconState: Equatable {
        case idle                             // plain icon
        case nextMeeting(title: String, timeText: String)  // icon + "Standup -- in 12m"
        case recording                        // recording indicator
    }

    public var iconState: IconState {
        if core.runState == .recording(/* any */) || core.recording.state.isRecording {
            return .recording
        }
        if let next = core.upcoming.first, isWithin2Hours(next.start) {
            let title = truncateTitle(next.title, maxLength: 20)
            let time = Self.relativeTimeText(next.start)
            return .nextMeeting(title: title, timeText: time)
        }
        return .idle
    }

    // MARK: - Body state

    /// Whether a recording is in progress.
    public var isRecording: Bool {
        core.recording.state.isRecording
    }

    /// Elapsed recording time formatted as "MM:SS".
    public var elapsedText: String {
        RecordingViewModel.formatElapsed(core.recording.state.elapsed)
    }

    /// The next 2 upcoming meeting-like events.
    public var upcomingEvents: [CalendarEvent] {
        Array(core.upcoming.prefix(2))
    }

    /// The last 2 recorded meetings.
    public var recentMeetings: [MeetingSummary] {
        Array(core.summaries.prefix(2))
    }

    // MARK: - Actions

    /// Start a new recording from the menu bar.
    public func startRecording() async {
        await core.startRecording()
    }

    /// Stop the current recording from the menu bar.
    public func stopRecording() async {
        await core.stopRecording()
    }

    /// Open the main window (and optionally navigate to a meeting).
    public func openApp(meetingID: UUID? = nil) {
        if let meetingID {
            core.select(meetingID)
        } else {
            core.showHome()
        }
        // NSApp.activate / window open is handled by the app target
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    /// Open the main window showing all meetings.
    public func seeAll() {
        core.showHome()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    /// Quit the application.
    public func quit() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Formatting helpers (pure, testable)

    /// Truncates a title to maxLength, preserving word boundaries, appending "..." if truncated.
    /// The time portion is never truncated (it's a separate field).
    public static func truncateTitle(_ title: String, maxLength: Int) -> String {
        guard title.count > maxLength else { return title }
        let truncated = String(title.prefix(maxLength))
        // Try to break at the last space
        if let lastSpace = truncated.lastIndex(of: " ") {
            return String(truncated[truncated.startIndex..<lastSpace]) + "\u{2026}"
        }
        return truncated + "\u{2026}"
    }

    /// Formats a future date as relative text: "in 5m", "in 1h 12m", "2:30 PM".
    public static func relativeTimeText(_ date: Date, relativeTo now: Date = Date()) -> String {
        let interval = date.timeIntervalSince(now)
        guard interval > 0 else { return "now" }
        let minutes = Int(interval / 60)
        if minutes < 60 {
            return "in \(minutes)m"
        }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        if remainingMinutes == 0 {
            return "in \(hours)h"
        }
        return "in \(hours)h \(remainingMinutes)m"
    }

    /// Whether a date is within 2 hours from now.
    public static func isWithin2Hours(_ date: Date, relativeTo now: Date = Date()) -> Bool {
        let interval = date.timeIntervalSince(now)
        return interval > 0 && interval <= 2 * 3600
    }
}
```

**Note on `runState` pattern matching:** The `iconState` computed property checks `core.runState`
for a recording case. Since `RunState.recording(UUID)` carries an associated value, the check is
`if case .recording = core.runState`. The VM also cross-checks `core.recording.state.isRecording`
for defense-in-depth.

#### View structure

The app target declares:
```swift
MenuBarExtra {
    MenuBarContentView(viewModel: menuBarViewModel)
} label: {
    MenuBarLabelView(viewModel: menuBarViewModel)
}
.menuBarExtraStyle(.window)  // popover-style body
```

`MenuBarLabelView`:
```
HStack(spacing: 4)
  Image(systemName: iconState == .recording ? "record.circle.fill" : "circle.dotted.circle")
  if case .nextMeeting(let title, let time) = iconState:
    Text("\(title) -- \(time)") .font(.caption) .monospacedDigit
```

`MenuBarContentView`:
```
VStack(alignment: .leading, spacing: 0)
  // Recording section
  if isRecording:
    HStack
      Circle.fill(.red) .frame(8,8)
      Text(elapsedText) .monospacedDigit
      Spacer
      Button("Stop") { stopRecording() }
    Divider
  else:
    Button("Start Recording") { startRecording() }
    Divider

  // Upcoming
  if !upcomingEvents.isEmpty:
    Text("Upcoming") .sectionHeaderFont .secondary
    ForEach upcomingEvents:
      UpcomingEventRow(title, timeText, platformBadge)
    Divider

  // Recent
  if !recentMeetings.isEmpty:
    Text("Recent") .sectionHeaderFont .secondary
    ForEach recentMeetings { meeting in
      Button { openApp(meetingID: meeting.id) } label:
        HStack: Text(meeting.title) + Text(relativeDate(meeting.date))
    }
    Button("See all...") { seeAll() }
    Divider

  // Footer
  Button("Open Biscotti") { openApp() }
  Button("Quit") { quit() }

.frame(width: 260)
.padding(spacingSM)
```

---

## Dependencies

Per architecture.md section 1, with the additions:

| Module | Internal deps | External |
|---|---|---|
| `HomeUI` | `AppCore`, `DataStore`, `Calendar`, `DesignSystem` | SwiftUI |
| `SearchUI` | `AppCore`, `DataStore`, `DesignSystem` | SwiftUI |
| `SettingsUI` | `AppCore`, `Calendar`, `Vocabulary`, `Permissions`, `DesignSystem` | SwiftUI |
| `OnboardingUI` | `AppCore`, `Permissions`, `Calendar`, `TranscriptionService`, `DesignSystem` | SwiftUI |
| `MenuBarUI` | `AppCore`, `DataStore`, `DesignSystem` | SwiftUI, AppKit (NSApplication for activate/terminate) |
| `MeetingDetailUI` (ext.) | `AppCore`, `DataStore`, `Calendar`, `TranscriptionService`, `DesignSystem` | SwiftUI, AVFoundation (via AudioPlaybackProviding seam) |
| `MeetingListUI` (ext.) | `AppCore`, `DataStore`, `DesignSystem` | SwiftUI |
| `AppShellUI` (ext.) | `AppCore`, `HomeUI`, `SearchUI`, `SettingsUI`, `OnboardingUI`, `MeetingListUI`, `RecordingUI`, `MeetingDetailUI`, `DesignSystem` | SwiftUI |

No cycles. All UI (L3) depends on AppCore (L2) and services (L1); never the reverse.

---

## Test Plan

All tests are headless swift-testing VM tests. Views are covered by `#Preview` providers in each
module. Tests construct the VM with a fake/preview `AppCore` (extending `PreviewAppCore` with the
new Stage C services) and assert on the VM's computed state and action side-effects.

### HomeUI tests

| Test name | Verifies |
|---|---|
| `homeShowsUpcomingPreview` | `upcomingPreview` returns first 3 events from `core.upcoming` when calendar authorized. |
| `homeEmptyWhenNoCalendarAccess` | `showConnectCalendar == true` when `calendar.auth != .authorized`; `upcomingPreview` is empty. |
| `homeNoUpcomingWhenAuthorizedButEmpty` | `showNoUpcoming == true` when authorized and `core.upcoming` is empty. |
| `homeStartDisabledWhileRecording` | `startDisabled == true` when `core.runState` is `.recording(...)`. |
| `homeTimeTextFormatsRelative` | `HomeViewModel.timeText(for:relativeTo:)` returns "in 12m" for 12-min-future event and "2:30 PM" for distant. |

### MeetingListUI tests

| Test name | Verifies |
|---|---|
| `pastListGroupsByEffectiveDate` | `groupByEffectiveDate` with meetings spanning today/yesterday/this-week/earlier produces correct groups. |
| `pastListOmitsEmptyGroups` | Meetings only in "Today" yields one group, not four. |
| `pastListSortsNewestFirst` | Within each group, meetings are ordered newest-first. |
| `groupingUsesEffectiveDate` | A meeting with `startDate` uses that; one with `nil` startDate uses `createdAt`. |
| `relativeDateFormatsCorrectly` | `relativeDate(_:)` produces abbreviated relative strings. |

### SearchUI tests

| Test name | Verifies |
|---|---|
| `searchReturnsRankedResults` | After `updateQuery("sam")`, `results` contains hits ranked by score (title > transcript). |
| `searchDebouncesCancelsPrior` | Rapid `updateQuery` calls cancel prior tasks; only the final query executes. |
| `searchNoResultsShowsMessage` | `showNoResults == true` and `noResultsMessage` contains the query when results are empty. |
| `searchBackRestoresRoute` | `dismiss()` calls `core.dismissSearch()`, which restores `searchReturnRoute`. |
| `searchRanksTitleAboveTranscript` | A hit matching in title has higher score than one matching only in transcript. |
| `matchedFieldsTextFormats` | `matchedFieldsText([.title, .transcript])` returns `"title, transcript"`. |
| `searchEmptyQueryClearsResults` | `updateQuery("")` sets `results = []` without calling the store. |

### MeetingDetailUI tests

| Test name | Verifies |
|---|---|
| `detailLoadsCalendarContext` | After `load()`, `calendarContext` is populated from the store. |
| `detailLoadsVersions` | `versions` contains all `TranscriptVersionData` for the meeting. |
| `versionPickerLoadsSelectedVersion` | `selectVersion(id)` sets `selectedVersionID` and loads the transcript for that version. |
| `displayedTranscriptReflectsSelection` | `displayedTranscript` returns the selected version's transcript, not the preferred. |
| `notesAutosaveDebounces` | `updateNotes("text")` debounces 1s before calling `store.setNotes`. |
| `playbackDisabledWhenAudioMissing` | `canPlay == false` when `audioFileRefs.present == false`. |
| `playPauseToggles` | `playPause()` toggles the audio player between play and pause states. |
| `seekUpdatesCurrentTime` | `seek(to: 30.0)` sets `audioPlayer.currentTime` to 30.0. |
| `associationCorrectionOffersReTranscribe` | After `correctAssociation(eventKey:)`, the VM surfaces a prompt (flag) suggesting re-transcribe. |
| `removeAssociationClearsContext` | `removeAssociation()` sets `calendarContext` to nil. |
| `processingStatePreserved` | Stage B processing/failed/transcript display states work unchanged. |

### SettingsUI tests

| Test name | Verifies |
|---|---|
| `settingsToggleLaunchAtLogin` | Setting `launchAtLogin = false` calls through to AppCore/settings update. |
| `calendarTogglePersistsEnabledIDs` | `toggleCalendar(id)` updates `enabledCalendarIDs` and persists via store. |
| `calendarGroupsBySource` | `calendarGroups` groups `CalendarInfo` items by `sourceTitle`. |
| `calendarAllEnabledWhenNil` | When `enabledCalendarIDs == nil`, `isCalendarEnabled` returns true for all. |
| `vocabularyAddRemove` | `addTerm` / `removeTerm` update `vocabularyTerms` and persist via VocabularyService. |
| `vocabularyUpdateTerm` | `updateTerm(at:to:)` replaces the term and persists. |
| `permissionsShowCurrentState` | Each permission computed property reflects the current `Permissions` state. |

### OnboardingUI tests

| Test name | Verifies |
|---|---|
| `onboardingAdvancesThroughSteps` | Calling `advance()` repeatedly walks from `.welcome` through `.done`. |
| `onboardingSkipSkipsPermission` | `skip()` on `.microphone` advances to `.systemAudio` without requesting. |
| `onboardingCalendarSelectionShownWhenGranted` | After granting calendar on `.calendar` step, `advance()` goes to `.calendarSelection`. |
| `onboardingCalendarSelectionSkippedWhenDenied` | After denying calendar, `advance()` goes to `.notifications` (skips selection). |
| `onboardingModelDownloadSkippable` | `skip()` on `.modelDownload` advances to `.done`. |
| `onboardingModelDownloadProgress` | `startDownload()` sets `isDownloading = true` and updates `downloadStatus`. |
| `onboardingCompletePersistsFlag` | `completeOnboarding()` calls `core.completeOnboarding()`. |
| `onboardingProgressIndexMapsCorrectly` | `progressIndex` returns the expected value for each step. |
| `onboardingDiskCheckSurfacesWarning` | When disk space is insufficient, `hasSufficientDisk == false`. |

### MenuBarUI tests

| Test name | Verifies |
|---|---|
| `menuBarIconIdleWhenNoUpcoming` | `iconState == .idle` when not recording and no upcoming within 2h. |
| `menuBarIconShowsNextMeetingWithin2h` | `iconState == .nextMeeting(...)` when the next event is within 2h. |
| `menuBarIconShowsRecordingWhenActive` | `iconState == .recording` when `core.runState` is recording. |
| `menuBarTruncatesTitleNotTime` | `truncateTitle("Very Long Meeting Name", maxLength: 15)` truncates at word boundary with ellipsis. |
| `menuBarRelativeTimeFormats` | `relativeTimeText` returns "in 5m", "in 1h 12m", "now" for various intervals. |
| `menuBarIsWithin2Hours` | `isWithin2Hours` returns true for 1h future, false for 3h future. |
| `menuBarUpcomingLimitedTo2` | `upcomingEvents` returns at most 2 items from `core.upcoming`. |
| `menuBarRecentLimitedTo2` | `recentMeetings` returns at most 2 items from `core.summaries`. |
| `menuBarStartRecordingDelegates` | `startRecording()` calls `core.startRecording()`. |
| `menuBarStopRecordingDelegates` | `stopRecording()` calls `core.stopRecording()`. |
