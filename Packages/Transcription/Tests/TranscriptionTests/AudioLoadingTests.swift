import Foundation
import Testing
@testable import Transcription

@Suite("AudioLoading single-track support")
struct AudioLoadingTests {
    @Test("loadAndMerge with system-only (nil mic) returns samples")
    func loadAndMerge_systemOnly() throws {
        let systemURL = try #require(Bundle.module.url(
            forResource: "system_fixture", withExtension: "wav",
            subdirectory: "Fixtures"
        ))
        let result = try AudioLoading.loadAndMerge(
            micPath: nil, systemPath: systemURL.path
        )

        // Should produce non-empty samples from the system track alone
        #expect(!result.samples.isEmpty)
        #expect(result.duration > 0)
    }

    @Test("loadAndMerge with mic-only (nil system) returns samples")
    func loadAndMerge_micOnly() throws {
        let micURL = try #require(Bundle.module.url(
            forResource: "mic_fixture", withExtension: "wav",
            subdirectory: "Fixtures"
        ))
        let result = try AudioLoading.loadAndMerge(
            micPath: micURL.path, systemPath: nil
        )

        // Should produce non-empty samples from the mic track alone
        #expect(!result.samples.isEmpty)
        #expect(result.duration > 0)
    }

    @Test("loadAndMerge with both nil throws invalidInput")
    func loadAndMerge_bothNil_throwsInvalidInput() {
        #expect(throws: TranscriptionError.self) {
            _ = try AudioLoading.loadAndMerge(micPath: nil, systemPath: nil)
        }
    }

    @Test("loadAndMerge with both paths returns merged samples")
    func loadAndMerge_bothPresent() throws {
        let micURL = try #require(Bundle.module.url(
            forResource: "mic_fixture", withExtension: "wav",
            subdirectory: "Fixtures"
        ))
        let systemURL = try #require(Bundle.module.url(
            forResource: "system_fixture", withExtension: "wav",
            subdirectory: "Fixtures"
        ))
        let result = try AudioLoading.loadAndMerge(
            micPath: micURL.path, systemPath: systemURL.path
        )

        #expect(!result.samples.isEmpty)
        #expect(result.duration > 0)
    }
}
