import Testing
@testable import Transcription

@Suite("TranscriptionDownloadSize")
struct TranscriptionDownloadSizeTests {
    @Test("estimatedBytes for current method returns a positive value")
    func currentMethodReturnsPositive() {
        let bytes = TranscriptionDownloadSize.estimatedBytes(method: .current)
        #expect(bytes > 0)
    }

    @Test("estimatedBytes for v1 matches the 626MB model variant")
    func v1MatchesExpectedVariant() {
        // V1 uses the 626MB model; estimate should be ~750 MB
        let bytes = TranscriptionDownloadSize.estimatedBytes(method: .v1)
        #expect(bytes == 750_000_000)
    }

    @Test("internal lookup for known model variants")
    func knownVariants() {
        #expect(TranscriptionDownloadSize.estimatedBytes(sttModel: "foo_1307MB_bar") == 1_400_000_000)
        #expect(TranscriptionDownloadSize.estimatedBytes(sttModel: "foo_1049MB_bar") == 1_150_000_000)
        #expect(TranscriptionDownloadSize.estimatedBytes(sttModel: "foo_954MB_bar") == 1_050_000_000)
        #expect(TranscriptionDownloadSize.estimatedBytes(sttModel: "foo_626MB_bar") == 750_000_000)
    }

    @Test("internal lookup for unknown model falls back to large estimate")
    func unknownModelFallback() {
        #expect(TranscriptionDownloadSize.estimatedBytes(sttModel: "unknown_model") == 3_300_000_000)
    }
}
