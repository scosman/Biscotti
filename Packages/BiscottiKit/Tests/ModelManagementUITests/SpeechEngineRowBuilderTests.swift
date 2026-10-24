import Testing
import TranscriptionService
@testable import ModelManagementUI

// MARK: - Helpers

/// Builds a base snapshot with reasonable defaults (Apple available,
/// Whisper downloaded, target Whisper, no in-flight work).
private func baseSnapshot(
    availability: AppleSpeechAvailability = .available,
    recommended: SpeechEngine = .whisper,
    target: SpeechEngine = .whisper,
    apple: EngineDownloadState = .downloaded,
    whisper: EngineDownloadState = .downloaded,
    hasEnoughDiskForWhisper: Bool = true,
    isAnyDownloadInFlight: Bool = false,
    isJobInFlight: Bool = false,
    osMajor: Int = 26
) -> SpeechEngineSnapshot {
    SpeechEngineSnapshot(
        availability: availability,
        recommended: recommended,
        target: target,
        apple: apple,
        whisper: whisper,
        hasEnoughDiskForWhisper: hasEnoughDiskForWhisper,
        isAnyDownloadInFlight: isAnyDownloadInFlight,
        isJobInFlight: isJobInFlight,
        osMajor: osMajor
    )
}

/// Returns the Apple row from the builder output.
private func appleRow(_ snap: SpeechEngineSnapshot) -> SpeechEngineRow {
    SpeechEngineRowBuilder.rows(snap)[0]
}

/// Returns the Whisper row from the builder output.
private func whisperRow(_ snap: SpeechEngineSnapshot) -> SpeechEngineRow {
    SpeechEngineRowBuilder.rows(snap)[1]
}

// MARK: - Row ordering and identity

@Suite("SpeechEngineRowBuilder")
struct SpeechEngineRowBuilderTests {
    @Test("Returns two rows: Apple first, Whisper second")
    func rowOrder() {
        let rows = SpeechEngineRowBuilder.rows(baseSnapshot())
        #expect(rows.count == 2)
        #expect(rows[0].engine == .apple)
        #expect(rows[1].engine == .whisper)
    }

    // MARK: - Recommended badge

    @Test("Recommended badge follows snapshot.recommended")
    func recommendedBadge() {
        let snap = baseSnapshot(recommended: .apple)
        let apple = appleRow(snap)
        let whisper = whisperRow(snap)
        #expect(apple.isRecommended == true)
        #expect(whisper.isRecommended == false)

        let snap2 = baseSnapshot(recommended: .whisper)
        #expect(appleRow(snap2).isRecommended == false)
        #expect(whisperRow(snap2).isRecommended == true)
    }

    // MARK: - Apple unavailable states

    @Test("Apple row is unavailable on macOS 15")
    func appleUnavailableMacOS15() {
        let snap = baseSnapshot(
            availability: .requiresOSUpdate(currentMajor: 15),
            apple: .notDownloaded
        )
        let row = appleRow(snap)
        #expect(row.unavailable == .requiresOSUpdate)
        #expect(row.selection == .none)
        #expect(row.action == .none)
        #expect(row.progress == .none)
    }

    @Test("Apple row is unavailable on non-Apple-silicon Mac")
    func appleUnavailableHardware() {
        let snap = baseSnapshot(
            availability: .unavailable,
            apple: .notDownloaded
        )
        let row = appleRow(snap)
        #expect(row.unavailable == .notAvailable)
        #expect(row.selection == .none)
        #expect(row.action == .none)
    }

    // MARK: - Apple available states

    @Test("Apple ready and target shows isDefault")
    func appleReadyTarget() {
        let snap = baseSnapshot(target: .apple, apple: .downloaded)
        let row = appleRow(snap)
        #expect(row.unavailable == nil)
        #expect(row.selection == .isDefault)
        #expect(row.action == .none)
        #expect(row.progress == .none)
    }

    @Test("Apple ready but not target shows choose")
    func appleReadyNotTarget() {
        let snap = baseSnapshot(target: .whisper, apple: .downloaded)
        let row = appleRow(snap)
        #expect(row.selection == .choose)
    }

    @Test("Apple not downloaded shows download action")
    func appleNotDownloaded() {
        let snap = baseSnapshot(apple: .notDownloaded)
        let row = appleRow(snap)
        #expect(row.selection == .none)
        #expect(row.action == .download(enabled: true))
    }

    @Test("Apple download disabled when another download is in flight")
    func appleDownloadDisabledInFlight() {
        let snap = baseSnapshot(
            apple: .notDownloaded,
            isAnyDownloadInFlight: true
        )
        let row = appleRow(snap)
        #expect(row.action == .download(enabled: false))
    }

    @Test("Apple downloading with determinate progress")
    func appleDownloadingDeterminate() {
        let snap = baseSnapshot(apple: .downloading(fraction: 0.42))
        let row = appleRow(snap)
        #expect(row.progress == .determinate(0.42))
        #expect(row.action == .none)
    }

    @Test("Apple downloading with indeterminate progress")
    func appleDownloadingIndeterminate() {
        let snap = baseSnapshot(apple: .downloading(fraction: nil))
        let row = appleRow(snap)
        #expect(row.progress == .indeterminate)
        #expect(row.action == .none)
    }

    @Test("Apple failed shows retry")
    func appleFailed() {
        let snap = baseSnapshot(apple: .failed(message: "Network error"))
        let row = appleRow(snap)
        #expect(row.progress == .failed("Network error"))
        #expect(row.action == .retry)
    }

    // MARK: - Apple traits

    @Test("Apple traits when ready")
    func appleTraitsReady() {
        let snap = baseSnapshot(apple: .downloaded)
        let row = appleRow(snap)
        #expect(row.traits.count == 4)
        #expect(row.traits[0].text == "5\u{00D7} faster")
        #expect(row.traits[0].isPro == true)
        #expect(row.traits[1].text == "Built in, no download")
        #expect(row.traits[1].isPro == true)
        #expect(row.traits[2].text == "1 language")
        #expect(row.traits[2].isPro == false)
        #expect(row.traits[2].hasLocalePicker == true)
        #expect(row.traits[3].text == "No custom vocabulary")
        #expect(row.traits[3].isPro == false)
    }

    @Test("Apple traits when not ready show 'Built into macOS'")
    func appleTraitsNotReady() {
        let snap = baseSnapshot(apple: .notDownloaded)
        let row = appleRow(snap)
        #expect(row.traits[1].text == "Built into macOS")
    }

    @Test("Apple locale picker hidden when unavailable")
    func appleLocalePickerHidden() {
        let snap = baseSnapshot(
            availability: .requiresOSUpdate(currentMajor: 15),
            apple: .notDownloaded
        )
        let row = appleRow(snap)
        #expect(row.traits[2].hasLocalePicker == false)
    }

    // MARK: - Apple technical line

    @Test("Apple technical line when ready")
    func appleTechLineReady() {
        let snap = baseSnapshot(apple: .downloaded, osMajor: 26)
        let row = appleRow(snap)
        #expect(row.technicalLine == "SpeechTranscriber \u{00B7} macOS 26")
    }

    @Test("Apple technical line when not ready includes 'system download'")
    func appleTechLineNotReady() {
        let snap = baseSnapshot(apple: .notDownloaded, osMajor: 26)
        let row = appleRow(snap)
        #expect(
            row.technicalLine
                == "SpeechTranscriber \u{00B7} macOS 26 \u{00B7} system download"
        )
    }

    // MARK: - Whisper states

    @Test("Whisper ready and target shows isDefault and delete")
    func whisperReadyTarget() {
        let snap = baseSnapshot(target: .whisper, whisper: .downloaded)
        let row = whisperRow(snap)
        #expect(row.unavailable == nil)
        #expect(row.selection == .isDefault)
        #expect(row.action == .delete(enabled: true))
    }

    @Test("Whisper ready but not target shows choose and delete")
    func whisperReadyNotTarget() {
        let snap = baseSnapshot(target: .apple, whisper: .downloaded)
        let row = whisperRow(snap)
        #expect(row.selection == .choose)
        #expect(row.action == .delete(enabled: true))
    }

    @Test("Whisper delete disabled during transcription job")
    func whisperDeleteDisabledDuringJob() {
        let snap = baseSnapshot(
            target: .whisper,
            whisper: .downloaded,
            isJobInFlight: true
        )
        let row = whisperRow(snap)
        #expect(row.action == .delete(enabled: false))
    }

    @Test("Whisper not downloaded shows download")
    func whisperNotDownloaded() {
        let snap = baseSnapshot(whisper: .notDownloaded)
        let row = whisperRow(snap)
        #expect(row.selection == .none)
        #expect(row.action == .download(enabled: true))
    }

    @Test("Whisper download disabled when another download is in flight")
    func whisperDownloadDisabledInFlight() {
        let snap = baseSnapshot(
            whisper: .notDownloaded,
            isAnyDownloadInFlight: true
        )
        let row = whisperRow(snap)
        #expect(row.action == .download(enabled: false))
    }

    @Test("Whisper download disabled with insufficient disk")
    func whisperDownloadDisabledNoDisk() {
        let snap = baseSnapshot(
            whisper: .notDownloaded,
            hasEnoughDiskForWhisper: false
        )
        let row = whisperRow(snap)
        #expect(row.action == .download(enabled: false))
        #expect(row.progress == .insufficientDisk)
    }

    @Test("Whisper downloading shows indeterminate progress")
    func whisperDownloading() {
        let snap = baseSnapshot(whisper: .downloading(fraction: nil))
        let row = whisperRow(snap)
        #expect(row.progress == .indeterminate)
        #expect(row.action == .none)
    }

    @Test("Whisper failed shows retry")
    func whisperFailed() {
        let snap = baseSnapshot(whisper: .failed(message: "Disk full"))
        let row = whisperRow(snap)
        #expect(row.progress == .failed("Disk full"))
        #expect(row.action == .retry)
    }

    // MARK: - Whisper traits

    @Test("Whisper traits are correct")
    func whisperTraits() {
        let row = whisperRow(baseSnapshot())
        #expect(row.traits.count == 4)
        #expect(row.traits[0].text == "Better with jargon & rare words")
        #expect(row.traits[0].isPro == true)
        #expect(row.traits[1].text == "Any of 99 languages")
        #expect(row.traits[1].isPro == true)
        #expect(row.traits[2].text == "Custom vocabulary")
        #expect(row.traits[2].isPro == true)
        #expect(row.traits[3].text == "5\u{00D7} slower")
        #expect(row.traits[3].isPro == false)
    }

    @Test("Whisper technical line is fixed")
    func whisperTechLine() {
        let row = whisperRow(baseSnapshot())
        #expect(row.technicalLine == "Whisper V3 Turbo \u{00B7} 626 MB")
    }

    // MARK: - Names

    @Test("Row names are correct")
    func rowNames() {
        let rows = SpeechEngineRowBuilder.rows(baseSnapshot())
        #expect(rows[0].name == "Apple Speech")
        #expect(rows[1].name == "Whisper")
    }
}
