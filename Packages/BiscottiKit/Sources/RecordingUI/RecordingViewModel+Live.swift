import Foundation
import LiveTranscriptionService
import LiveTranscriptModel
import Recording
import TranscriptUI

/// One choice in the drawer's language menu.
public struct LiveLanguageChoice: Identifiable, Equatable, Sendable {
    public let language: LiveLanguage
    public let title: String
    public let subtitle: String?

    public var id: LiveLanguage {
        language
    }
}

/// The drawer's items and the live state they were built from.
struct LiveItemsCache {
    let rows: [LiveRow]
    let gaps: [LiveGap]
    let startMarker: TimeInterval?
    let items: [TranscriptItem]
}

// MARK: - Live transcript

/// The live drawer's state and actions, projected from
/// `core.liveTranscription`. Views that redraw often read only what they
/// draw: the level meter reads `liveLevel`, the list reads `liveItems`.
public extension RecordingViewModel {
    private var live: LiveTranscriptionService {
        core.liveTranscription
    }

    var liveStatus: LiveStatus {
        live.status
    }

    /// The toggle and drawer exist only while live transcription runs for
    /// this recording, including when it is unavailable.
    var showsLiveTranscript: Bool {
        live.isVisible
    }

    /// When the current Starting began, while starting.
    var liveStartingSince: Date? {
        live.startingSince
    }

    /// 0…1, about 12 updates a second while live.
    var liveLevel: Float {
        live.level
    }

    /// The drawer's bubbles, without run labels. Rebuilt only when the rows,
    /// the gaps or the start marker change, not on every redraw.
    var liveItems: [TranscriptItem] {
        let rows = live.rows
        let gaps = live.gaps
        let marker = live.startMarker
        if let cache = liveItemsCache, cache.rows == rows, cache.gaps == gaps, cache.startMarker == marker {
            return cache.items
        }
        let items = TranscriptItemBuilder.live(rows: rows, gaps: gaps, startMarker: marker, labelStyle: .none)
        liveItemsCache = LiveItemsCache(rows: rows, gaps: gaps, startMarker: marker, items: items)
        return items
    }

    /// Changes whenever the drawer's rows do.
    var liveRowsRevision: Int {
        live.rowsRevision
    }

    /// The drawer drew a new revision of the rows, for the latency signposts.
    func liveRowsDrawn() {
        live.rowsDrawn()
    }

    var isDrawerExpanded: Bool {
        live.isDrawerExpanded
    }

    var liveLanguage: LiveLanguage {
        live.language
    }

    var detectedLanguageName: String? {
        live.detectedLanguageName
    }

    /// The moment the drawer should scroll to once. The list sets it to nil
    /// when it has scrolled, which marks the request handled.
    var revealTime: TimeInterval? {
        get { live.revealRequest?.time }
        set {
            guard newValue == nil, let request = live.revealRequest else { return }
            live.revealRequestHandled(request)
        }
    }

    /// The text beside the toggle in the open drawer. Live shows none, and
    /// neither does Catching up: the header shows it.
    var liveStatusText: String? {
        Self.statusText(for: live.status)
    }

    /// The height the user chose for the drawer, nil for the default.
    var liveDrawerHeight: CGFloat? {
        live.drawerHeight
    }

    /// Saves a dragged height, rounded to whole points.
    func setLiveDrawerHeight(_ height: CGFloat) {
        live.drawerHeight = height.rounded()
    }

    /// Back to the default height, which fits the window.
    func resetLiveDrawerHeight() {
        live.drawerHeight = nil
    }

    /// During a slow live start, whether the disk is low, as last read.
    var liveSlowStartIsLowOnDisk: Bool {
        core.transcription.isLowOnDiskSpace
    }

    /// Reads the free space once a live start has been slow for
    /// `LiveTranscriptDrawer.slowStartDelay`: a load that long compiled the
    /// model, and a low disk is why it had to.
    func checkDiskSpaceForSlowStart() async {
        await core.transcription.refreshDiskSpace()
    }

    /// The drawer's two lines while a live start is slow. Chosen by the user
    /// on 25 October 2026: say so when low disk space is why.
    static func slowStartMessages(lowOnDisk: Bool) -> [String] {
        if lowOnDisk {
            [
                "Your Mac is low on disk space, so macOS removed the prepared speech model.",
                "Preparing it again takes about 2 minutes. The transcript will catch up from the start."
            ]
        } else {
            [
                "Preparing the speech model.",
                "The first time takes a couple of minutes. The transcript will catch up from the start."
            ]
        }
    }

    /// The drawer's header shows `catchingUpText` with a spinner.
    var isLiveCatchingUp: Bool {
        Self.showsCatchingUp(for: live.status)
    }

    static func showsCatchingUp(for status: LiveStatus) -> Bool {
        status == .catchingUp
    }

    /// The toggle's VoiceOver value.
    var liveAccessibilityValue: String {
        Self.accessibilityValue(for: live.status)
    }

    var liveModelState: LiveModelState {
        live.modelState
    }

    /// Whether the live transcript has any text to copy.
    var canCopyLiveTranscript: Bool {
        live.rows.contains(where: \.hasText)
    }

    var languageChoices: [LiveLanguageChoice] {
        Self.whisperLanguageChoices
    }

    var languageMenuTitle: String {
        Self.languageTitle(language: live.language, detectedName: live.detectedLanguageName)
    }

    // MARK: Actions

    func toggleDrawer() {
        live.toggleDrawer()
    }

    func collapseDrawer() {
        live.isDrawerExpanded = false
    }

    func setLanguage(_ language: LiveLanguage) async {
        await live.setLanguage(language)
    }

    /// Copies the live transcript so far: one line per bubble, prefixed
    /// "You:" or "Others:".
    func copyLiveTranscript() {
        copyToPasteboard(LiveTranscriptText.render(live.rows))
    }

    /// Opens the drawer at the moment a note was taken. Note times count
    /// from capture start; the transcript's from the first mic buffer.
    func revealNoteInTranscript(_ note: MeetingNote) {
        let offset = core.recording.state.timelineOffset ?? 0
        live.reveal(atRecordingTime: note.timestamp + offset)
    }

    /// Downloads the live model; live transcription starts once it is on disk.
    func downloadLiveModel() async {
        await live.downloadModel()
    }

    // MARK: Text

    static let catchingUpText = "Catching up…"

    static func statusText(for status: LiveStatus) -> String? {
        switch status {
        case .off, .live, .catchingUp: nil
        case .starting: "Starting"
        case .paused: "Paused while the Mac cools down"
        case let .unavailable(reason): unavailableText(for: reason)
        }
    }

    static func unavailableText(for reason: UnavailableReason) -> String {
        switch reason {
        case .modelMissing: "Needs the transcription model"
        case .languageUnsupported: "Not available for this language"
        case .stopped: "Live transcript stopped"
        }
    }

    static func accessibilityValue(for status: LiveStatus) -> String {
        switch status {
        case .off, .unavailable: "Unavailable"
        case .starting: "Starting"
        case .live: "Live"
        case .catchingUp: "Catching up"
        case .paused: "Paused"
        }
    }

    /// Whisper offers English and Detect.
    static let whisperLanguageChoices = [
        LiveLanguageChoice(language: .english, title: "English", subtitle: "Best quality"),
        LiveLanguageChoice(
            language: .detect,
            title: "Detect language",
            subtitle: "Finds the language once, then keeps it"
        )
    ]

    /// The language menu's label: the detected language once Detect found it.
    static func languageTitle(language: LiveLanguage, detectedName: String?) -> String {
        switch language {
        case .english: "English"
        case .detect: detectedName ?? "Detect language"
        case let .locale(identifier): localeName(identifier)
        }
    }

    private static func localeName(_ identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }
}
