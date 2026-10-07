import Testing
@testable import Transcription

@Suite("SpeakerEmbeddingSpace")
struct SpeakerEmbeddingSpaceTests {
    @Test("Space key is version/variant")
    func keyFormat() {
        let key = SpeakerEmbeddingSpace.current()

        // On macOS 15+, embedder defaults to pyannote-v3/W8A16
        #expect(key.contains("/"))
        #expect(!key.contains("unknown"))
    }
}
