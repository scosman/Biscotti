import TranscriptionService

// MARK: - Snapshot (input)

/// Snapshot of SpeechEngineManager state consumed by the row builder.
/// Built once when rows are needed; avoids repeated observation reads.
public struct SpeechEngineSnapshot: Equatable, Sendable {
    public var availability: AppleSpeechAvailability
    public var recommended: SpeechEngine
    public var target: SpeechEngine
    public var apple: EngineDownloadState
    public var whisper: EngineDownloadState
    public var hasEnoughDiskForWhisper: Bool
    public var isAnyDownloadInFlight: Bool
    public var isJobInFlight: Bool
    public var osMajor: Int

    public init(
        availability: AppleSpeechAvailability,
        recommended: SpeechEngine,
        target: SpeechEngine,
        apple: EngineDownloadState,
        whisper: EngineDownloadState,
        hasEnoughDiskForWhisper: Bool,
        isAnyDownloadInFlight: Bool,
        isJobInFlight: Bool,
        osMajor: Int
    ) {
        self.availability = availability
        self.recommended = recommended
        self.target = target
        self.apple = apple
        self.whisper = whisper
        self.hasEnoughDiskForWhisper = hasEnoughDiskForWhisper
        self.isAnyDownloadInFlight = isAnyDownloadInFlight
        self.isJobInFlight = isJobInFlight
        self.osMajor = osMajor
    }
}

// MARK: - Row model (output)

/// View-model for a single row in the Speech to Text Model sheet.
public struct SpeechEngineRow: Equatable, Identifiable, Sendable {
    public enum Selection: Equatable, Sendable {
        case isDefault, choose, none
    }

    public enum Progress: Equatable, Sendable {
        case none, determinate(Double), indeterminate, failed(String), insufficientDisk
    }

    public enum Action: Equatable, Sendable {
        case download(enabled: Bool), retry, delete(enabled: Bool), none
    }

    public enum Unavailable: Equatable, Sendable {
        case requiresOSUpdate, notAvailable
    }

    public struct Trait: Equatable, Sendable {
        public let text: String
        public let isPro: Bool
        public let hasLocalePicker: Bool

        public init(text: String, isPro: Bool, hasLocalePicker: Bool = false) {
            self.text = text
            self.isPro = isPro
            self.hasLocalePicker = hasLocalePicker
        }
    }

    public let id: SpeechEngine
    public let engine: SpeechEngine
    public let name: String
    public let isRecommended: Bool
    public let unavailable: Unavailable?
    public let selection: Selection
    public let traits: [Trait]
    public let technicalLine: String
    public let progress: Progress
    public let action: Action

    public init(
        engine: SpeechEngine,
        name: String,
        isRecommended: Bool,
        unavailable: Unavailable?,
        selection: Selection,
        traits: [Trait],
        technicalLine: String,
        progress: Progress,
        action: Action
    ) {
        id = engine
        self.engine = engine
        self.name = name
        self.isRecommended = isRecommended
        self.unavailable = unavailable
        self.selection = selection
        self.traits = traits
        self.technicalLine = technicalLine
        self.progress = progress
        self.action = action
    }
}

// MARK: - Builder

/// Pure function that builds the two sheet rows from a snapshot.
public enum SpeechEngineRowBuilder {
    /// Returns `[apple, whisper]` rows for the sheet.
    public static func rows(_ snap: SpeechEngineSnapshot) -> [SpeechEngineRow] {
        [appleRow(snap), whisperRow(snap)]
    }

    // MARK: - Apple

    private static func appleRow(_ snap: SpeechEngineSnapshot) -> SpeechEngineRow {
        let unavailable = appleUnavailable(snap)
        let isReady = unavailable == nil && snap.apple == .downloaded
        let selection = appleSelection(unavailable: unavailable, isReady: isReady, snap: snap)
        let traits = appleTraits(unavailable: unavailable, isReady: isReady, snap: snap)
        let progress = appleProgress(unavailable: unavailable, snap: snap)
        let action = appleAction(unavailable: unavailable, isReady: isReady, snap: snap)
        let techLine = appleTechnicalLine(isReady: isReady, snap: snap)

        return SpeechEngineRow(
            engine: .apple,
            name: "Apple Speech",
            isRecommended: snap.recommended == .apple,
            unavailable: unavailable,
            selection: selection,
            traits: traits,
            technicalLine: techLine,
            progress: progress,
            action: action
        )
    }

    private static func appleUnavailable(_ snap: SpeechEngineSnapshot) -> SpeechEngineRow.Unavailable? {
        switch snap.availability {
        case .available:
            nil
        case .requiresOSUpdate:
            .requiresOSUpdate
        case .unavailable:
            .notAvailable
        }
    }

    private static func appleSelection(
        unavailable: SpeechEngineRow.Unavailable?,
        isReady: Bool,
        snap: SpeechEngineSnapshot
    ) -> SpeechEngineRow.Selection {
        if unavailable != nil { return .none }
        if isReady, snap.target == .apple { return .isDefault }
        if isReady { return .choose }
        return .none
    }

    private static func appleTraits(
        unavailable: SpeechEngineRow.Unavailable?,
        isReady: Bool,
        snap: SpeechEngineSnapshot
    ) -> [SpeechEngineRow.Trait] {
        let builtInText = isReady ? "Built in, no download" : "Built into macOS"
        let hasLocalePicker = unavailable == nil && (snap.availability == .available)
        return [
            .init(text: "5\u{00D7} faster", isPro: true),
            .init(text: builtInText, isPro: true),
            .init(text: "1 language", isPro: false, hasLocalePicker: hasLocalePicker),
            .init(text: "No custom vocabulary", isPro: false)
        ]
    }

    private static func appleProgress(
        unavailable: SpeechEngineRow.Unavailable?,
        snap: SpeechEngineSnapshot
    ) -> SpeechEngineRow.Progress {
        if unavailable != nil { return .none }
        switch snap.apple {
        case let .downloading(fraction):
            if let fraction { return .determinate(fraction) }
            return .indeterminate
        case let .failed(message):
            return .failed(message)
        default:
            return .none
        }
    }

    private static func appleAction(
        unavailable: SpeechEngineRow.Unavailable?,
        isReady: Bool,
        snap: SpeechEngineSnapshot
    ) -> SpeechEngineRow.Action {
        if unavailable != nil { return .none }
        if case .downloading = snap.apple { return .none }
        if case .failed = snap.apple { return .retry }
        if isReady { return .none }
        return .download(enabled: !snap.isAnyDownloadInFlight)
    }

    private static func appleTechnicalLine(isReady: Bool, snap: SpeechEngineSnapshot) -> String {
        var line = "SpeechTranscriber \u{00B7} macOS \(snap.osMajor)"
        if !isReady, snap.availability == .available {
            line += " \u{00B7} system download"
        }
        return line
    }

    // MARK: - Whisper

    private static func whisperRow(_ snap: SpeechEngineSnapshot) -> SpeechEngineRow {
        let isReady = snap.whisper == .downloaded
        let selection = whisperSelection(isReady: isReady, snap: snap)
        let traits = whisperTraits()
        let progress = whisperProgress(isReady: isReady, snap: snap)
        let action = whisperAction(isReady: isReady, snap: snap)

        return SpeechEngineRow(
            engine: .whisper,
            name: "Whisper",
            isRecommended: snap.recommended == .whisper,
            unavailable: nil,
            selection: selection,
            traits: traits,
            technicalLine: "Whisper V3 Turbo \u{00B7} 626 MB",
            progress: progress,
            action: action
        )
    }

    private static func whisperSelection(
        isReady: Bool,
        snap: SpeechEngineSnapshot
    ) -> SpeechEngineRow.Selection {
        if isReady, snap.target == .whisper { return .isDefault }
        if isReady { return .choose }
        return .none
    }

    private static func whisperTraits() -> [SpeechEngineRow.Trait] {
        [
            .init(text: "Better with jargon & rare words", isPro: true),
            .init(text: "Any of 99 languages", isPro: true),
            .init(text: "Custom vocabulary", isPro: true),
            .init(text: "5\u{00D7} slower", isPro: false)
        ]
    }

    private static func whisperProgress(
        isReady: Bool,
        snap: SpeechEngineSnapshot
    ) -> SpeechEngineRow.Progress {
        switch snap.whisper {
        case .downloading:
            return .indeterminate
        case let .failed(message):
            return .failed(message)
        default:
            break
        }
        if !isReady, !snap.hasEnoughDiskForWhisper {
            return .insufficientDisk
        }
        return .none
    }

    private static func whisperAction(
        isReady: Bool,
        snap: SpeechEngineSnapshot
    ) -> SpeechEngineRow.Action {
        if case .downloading = snap.whisper { return .none }
        if case .failed = snap.whisper { return .retry }
        if isReady { return .delete(enabled: !snap.isJobInFlight) }
        return .download(enabled: !snap.isAnyDownloadInFlight && snap.hasEnoughDiskForWhisper)
    }
}
