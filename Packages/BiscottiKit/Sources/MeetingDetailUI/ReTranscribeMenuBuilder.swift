import TranscriptionService

/// A single item in the Re-transcribe engine submenu.
public struct ReTranscribeMenuItem: Equatable, Identifiable, Sendable {
    /// The engine this item represents.
    public let engine: SpeechEngine

    /// Display title including parenthetical reason or current marker.
    public let title: String

    /// Whether the item can be selected (engine is ready, no job in flight).
    public let isEnabled: Bool

    public var id: SpeechEngine {
        engine
    }
}

/// Builds the Re-transcribe submenu items from engine state.
///
/// Pure and testable: no dependencies on managers or views. Produces
/// two items (Apple, then Whisper) with reason text per functional
/// spec section 12.2.
public enum ReTranscribeMenuBuilder {
    /// Builds the submenu items.
    ///
    /// - Parameters:
    ///   - appleAvailability: Current Apple Speech availability.
    ///   - apple: Apple asset download state.
    ///   - whisper: Whisper model download state.
    ///   - currentEngine: The engine that produced the meeting's newest
    ///     transcript version, or nil when no versions exist.
    /// - Returns: Two items in order: Apple Speech, Whisper.
    public static func items(
        appleAvailability: AppleSpeechAvailability,
        apple: EngineDownloadState,
        whisper: EngineDownloadState,
        currentEngine: SpeechEngine?
    ) -> [ReTranscribeMenuItem] {
        [
            appleItem(
                availability: appleAvailability,
                state: apple,
                isCurrent: currentEngine == .apple
            ),
            whisperItem(
                state: whisper,
                isCurrent: currentEngine == .whisper
            )
        ]
    }

    // MARK: - Apple item

    private static func appleItem(
        availability: AppleSpeechAvailability,
        state: EngineDownloadState,
        isCurrent: Bool
    ) -> ReTranscribeMenuItem {
        let baseName = "Apple Speech"

        // Unavailable reasons take priority over download state
        switch availability {
        case .requiresOSUpdate:
            return ReTranscribeMenuItem(
                engine: .apple,
                title: "\(baseName) (requires macOS 26)",
                isEnabled: false
            )
        case .unavailable:
            return ReTranscribeMenuItem(
                engine: .apple,
                title: "\(baseName) (not available on this Mac)",
                isEnabled: false
            )
        case .available:
            break
        }

        // Download state reasons
        if let reason = downloadReason(state) {
            return ReTranscribeMenuItem(
                engine: .apple,
                title: "\(baseName) (\(reason))",
                isEnabled: false
            )
        }

        // Ready
        let suffix = isCurrent ? " (current transcription)" : ""
        return ReTranscribeMenuItem(
            engine: .apple,
            title: "\(baseName)\(suffix)",
            isEnabled: true
        )
    }

    // MARK: - Whisper item

    private static func whisperItem(
        state: EngineDownloadState,
        isCurrent: Bool
    ) -> ReTranscribeMenuItem {
        let baseName = "Whisper"

        if let reason = downloadReason(state) {
            return ReTranscribeMenuItem(
                engine: .whisper,
                title: "\(baseName) (\(reason))",
                isEnabled: false
            )
        }

        let suffix = isCurrent ? " (current transcription)" : ""
        return ReTranscribeMenuItem(
            engine: .whisper,
            title: "\(baseName)\(suffix)",
            isEnabled: true
        )
    }

    // MARK: - Shared

    /// Maps a non-ready download state to a parenthetical reason string.
    /// Returns nil when the engine is downloaded (ready).
    private static func downloadReason(
        _ state: EngineDownloadState
    ) -> String? {
        switch state {
        case .notDownloaded:
            "not downloaded"
        case .downloading:
            "downloading\u{2026}"
        case .failed:
            "download failed"
        case .downloaded:
            nil
        }
    }
}
