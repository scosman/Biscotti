import Foundation
import Testing
import TranscriptionService
@testable import MeetingDetailUI

@Suite("ReTranscribeMenuBuilder")
struct ReTranscribeMenuBuilderTests {
    // MARK: - Order

    @Test("Items are ordered Apple then Whisper")
    func orderAppleThenWhisper() {
        let items = ReTranscribeMenuBuilder.items(
            appleAvailability: .available,
            apple: .downloaded,
            whisper: .downloaded,
            currentEngine: nil
        )
        #expect(items.count == 2)
        #expect(items[0].engine == .apple)
        #expect(items[1].engine == .whisper)
    }

    // MARK: - Current marker

    @Test("Apple shows current marker when newest version is Apple")
    func appleCurrentMarker() {
        let items = ReTranscribeMenuBuilder.items(
            appleAvailability: .available,
            apple: .downloaded,
            whisper: .downloaded,
            currentEngine: .apple
        )
        #expect(items[0].title == "Apple Speech (current transcription)")
        #expect(items[0].isEnabled == true)
        #expect(items[1].title == "Whisper")
        #expect(items[1].isEnabled == true)
    }

    @Test("Whisper shows current marker when newest version is Whisper")
    func whisperCurrentMarker() {
        let items = ReTranscribeMenuBuilder.items(
            appleAvailability: .available,
            apple: .downloaded,
            whisper: .downloaded,
            currentEngine: .whisper
        )
        #expect(items[0].title == "Apple Speech")
        #expect(items[1].title == "Whisper (current transcription)")
    }

    @Test("No current marker when no versions exist")
    func noMarkerWhenNoVersions() {
        let items = ReTranscribeMenuBuilder.items(
            appleAvailability: .available,
            apple: .downloaded,
            whisper: .downloaded,
            currentEngine: nil
        )
        #expect(items[0].title == "Apple Speech")
        #expect(items[1].title == "Whisper")
    }

    // MARK: - Apple unavailable

    @Test("Apple shows requires macOS 26 on macOS 15")
    func appleRequiresOSUpdate() {
        let items = ReTranscribeMenuBuilder.items(
            appleAvailability: .requiresOSUpdate(currentMajor: 15),
            apple: .notDownloaded,
            whisper: .downloaded,
            currentEngine: .whisper
        )
        #expect(items[0].title == "Apple Speech (requires macOS 26)")
        #expect(items[0].isEnabled == false)
        // Whisper still enabled
        #expect(items[1].isEnabled == true)
    }

    @Test("Apple shows not available when SpeechTranscriber unavailable")
    func appleNotAvailable() {
        let items = ReTranscribeMenuBuilder.items(
            appleAvailability: .unavailable,
            apple: .notDownloaded,
            whisper: .downloaded,
            currentEngine: .whisper
        )
        #expect(items[0].title == "Apple Speech (not available on this Mac)")
        #expect(items[0].isEnabled == false)
    }

    // MARK: - Download states

    @Test("Apple not downloaded shows reason")
    func appleNotDownloaded() {
        let items = ReTranscribeMenuBuilder.items(
            appleAvailability: .available,
            apple: .notDownloaded,
            whisper: .downloaded,
            currentEngine: .whisper
        )
        #expect(items[0].title == "Apple Speech (not downloaded)")
        #expect(items[0].isEnabled == false)
    }

    @Test("Apple downloading shows reason")
    func appleDownloading() {
        let items = ReTranscribeMenuBuilder.items(
            appleAvailability: .available,
            apple: .downloading(fraction: 0.5),
            whisper: .downloaded,
            currentEngine: .whisper
        )
        #expect(items[0].title == "Apple Speech (downloading\u{2026})")
        #expect(items[0].isEnabled == false)
    }

    @Test("Apple download failed shows reason")
    func appleDownloadFailed() {
        let items = ReTranscribeMenuBuilder.items(
            appleAvailability: .available,
            apple: .failed(message: "Network error"),
            whisper: .downloaded,
            currentEngine: .whisper
        )
        #expect(items[0].title == "Apple Speech (download failed)")
        #expect(items[0].isEnabled == false)
    }

    @Test("Whisper not downloaded shows reason")
    func whisperNotDownloaded() {
        let items = ReTranscribeMenuBuilder.items(
            appleAvailability: .available,
            apple: .downloaded,
            whisper: .notDownloaded,
            currentEngine: .apple
        )
        #expect(items[1].title == "Whisper (not downloaded)")
        #expect(items[1].isEnabled == false)
    }

    @Test("Whisper downloading shows reason")
    func whisperDownloading() {
        let items = ReTranscribeMenuBuilder.items(
            appleAvailability: .available,
            apple: .downloaded,
            whisper: .downloading(fraction: nil),
            currentEngine: .apple
        )
        #expect(items[1].title == "Whisper (downloading\u{2026})")
        #expect(items[1].isEnabled == false)
    }

    @Test("Whisper download failed shows reason")
    func whisperFailed() {
        let items = ReTranscribeMenuBuilder.items(
            appleAvailability: .available,
            apple: .downloaded,
            whisper: .failed(message: "Disk full"),
            currentEngine: .apple
        )
        #expect(items[1].title == "Whisper (download failed)")
        #expect(items[1].isEnabled == false)
    }

    // MARK: - Reason replaces current marker

    @Test("Disabled reason replaces current marker when engine is current but not ready")
    func reasonReplacesCurrentMarker() {
        // Apple is current but downloading: shows reason, not current marker
        let items = ReTranscribeMenuBuilder.items(
            appleAvailability: .available,
            apple: .downloading(fraction: 0.3),
            whisper: .downloaded,
            currentEngine: .apple
        )
        #expect(items[0].title == "Apple Speech (downloading\u{2026})")
        #expect(items[0].isEnabled == false)
    }

    // MARK: - Both ready

    @Test("Both ready, no current -- both enabled, neither marked")
    func bothReadyNoCurrent() {
        let items = ReTranscribeMenuBuilder.items(
            appleAvailability: .available,
            apple: .downloaded,
            whisper: .downloaded,
            currentEngine: nil
        )
        #expect(items[0].title == "Apple Speech")
        #expect(items[0].isEnabled == true)
        #expect(items[1].title == "Whisper")
        #expect(items[1].isEnabled == true)
    }
}
