import Testing
@testable import Transcription

@Suite("SpeakerEmbeddingSpace")
struct SpeakerEmbeddingSpaceTests {
    @Test("Raw space key is version/variant")
    func rawKeyFormat() {
        let key = SpeakerEmbeddingSpace.current(.raw)

        // On macOS 15+, embedder defaults to pyannote-v3/W8A16
        #expect(key.contains("/"))
        #expect(!key.contains("+plda:"))
        #expect(!key.contains("unknown"))
    }

    @Test("PLDA space key extends raw with plda suffix")
    func pldaKeyFormat() {
        let key = SpeakerEmbeddingSpace.current(.plda)
        let rawKey = SpeakerEmbeddingSpace.current(.raw)

        // PLDA key starts with the raw key and adds "+plda:..."
        #expect(key.hasPrefix(rawKey + "+plda:"))
        #expect(!key.contains("unknown"))
    }

    @Test("Raw and PLDA keys are distinct")
    func keysAreDistinct() {
        let rawKey = SpeakerEmbeddingSpace.current(.raw)
        let pldaKey = SpeakerEmbeddingSpace.current(.plda)

        #expect(rawKey != pldaKey)
    }
}
