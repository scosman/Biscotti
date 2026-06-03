import Foundation
import Testing
@testable import ArgMaxKit

@Suite("ArgMaxError")
struct ArgMaxErrorTests {

    @Test("invalidAudioFile has useful description")
    func invalidAudioFileDescription() {
        let error = ArgMaxError.invalidAudioFile(
            URL(fileURLWithPath: "/tmp/test.wav"),
            underlying: "File does not exist"
        )
        let desc = error.errorDescription!
        #expect(desc.contains("Invalid audio file"))
        #expect(desc.contains("/tmp/test.wav"))
        #expect(desc.contains("File does not exist"))
    }

    @Test("audioLoadFailed has useful description")
    func audioLoadFailedDescription() {
        let error = ArgMaxError.audioLoadFailed(
            URL(fileURLWithPath: "/tmp/bad.mp3"),
            underlying: "Unsupported format"
        )
        let desc = error.errorDescription!
        #expect(desc.contains("Failed to load audio"))
        #expect(desc.contains("/tmp/bad.mp3"))
        #expect(desc.contains("Unsupported format"))
    }

    @Test("modelLoadFailed has useful description")
    func modelLoadFailedDescription() {
        let error = ArgMaxError.modelLoadFailed("Network timeout")
        let desc = error.errorDescription!
        #expect(desc.contains("Failed to load ML models"))
        #expect(desc.contains("Network timeout"))
    }

    @Test("transcriptionFailed has useful description")
    func transcriptionFailedDescription() {
        let error = ArgMaxError.transcriptionFailed("Out of memory")
        let desc = error.errorDescription!
        #expect(desc.contains("Transcription failed"))
        #expect(desc.contains("Out of memory"))
    }

    @Test("diarizationFailed has useful description")
    func diarizationFailedDescription() {
        let error = ArgMaxError.diarizationFailed("Model not loaded")
        let desc = error.errorDescription!
        #expect(desc.contains("Diarization failed"))
        #expect(desc.contains("Model not loaded"))
    }

    @Test("All errors conform to LocalizedError")
    func conformsToLocalizedError() {
        let errors: [ArgMaxError] = [
            .invalidAudioFile(URL(fileURLWithPath: "/test"), underlying: "reason"),
            .audioLoadFailed(URL(fileURLWithPath: "/test"), underlying: "reason"),
            .modelLoadFailed("reason"),
            .transcriptionFailed("reason"),
            .diarizationFailed("reason"),
        ]

        for error in errors {
            #expect(error.errorDescription != nil)
            #expect(!error.errorDescription!.isEmpty)
        }
    }
}
