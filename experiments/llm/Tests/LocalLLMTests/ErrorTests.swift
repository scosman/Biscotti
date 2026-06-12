import Foundation
import Testing

@testable import LocalLLM

@Suite("LocalLLMError")
struct ErrorTests {
    @Test("modelFileNotFound has descriptive message")
    func modelFileNotFound() {
        let error = LocalLLMError.modelFileNotFound(URL(fileURLWithPath: "/path/to/model.gguf"))
        let desc = error.errorDescription!
        #expect(desc.contains("Model file not found"))
        #expect(desc.contains("/path/to/model.gguf"))
    }

    @Test("downloadFailed includes URL and underlying reason")
    func downloadFailed() {
        let error = LocalLLMError.downloadFailed(
            url: URL(string: "https://example.com/model.gguf")!,
            underlying: "HTTP 404"
        )
        let desc = error.errorDescription!
        #expect(desc.contains("Download failed"))
        #expect(desc.contains("example.com"))
        #expect(desc.contains("HTTP 404"))
    }

    @Test("modelLoadFailed includes detail")
    func modelLoadFailed() {
        let error = LocalLLMError.modelLoadFailed("null pointer")
        let desc = error.errorDescription!
        #expect(desc.contains("Failed to load model"))
        #expect(desc.contains("null pointer"))
    }

    @Test("contextCreationFailed includes detail")
    func contextCreationFailed() {
        let error = LocalLLMError.contextCreationFailed("out of memory")
        let desc = error.errorDescription!
        #expect(desc.contains("Failed to create context"))
        #expect(desc.contains("out of memory"))
    }

    @Test("tokenizationFailed includes detail")
    func tokenizationFailed() {
        let error = LocalLLMError.tokenizationFailed("buffer overflow")
        let desc = error.errorDescription!
        #expect(desc.contains("Tokenization failed"))
        #expect(desc.contains("buffer overflow"))
    }

    @Test("contextOverflow includes token counts")
    func contextOverflow() {
        let error = LocalLLMError.contextOverflow(promptTokens: 33000, contextSize: 32768)
        let desc = error.errorDescription!
        #expect(desc.contains("33000"))
        #expect(desc.contains("32768"))
        #expect(desc.contains("exceeds"))
    }

    @Test("generationFailed includes detail")
    func generationFailed() {
        let error = LocalLLMError.generationFailed("decode error")
        let desc = error.errorDescription!
        #expect(desc.contains("Generation failed"))
    }

    @Test("decodeFailed includes error code")
    func decodeFailed() {
        let error = LocalLLMError.decodeFailed(code: -1)
        let desc = error.errorDescription!
        #expect(desc.contains("-1"))
    }

    @Test("cancelled has description")
    func cancelled() {
        let error = LocalLLMError.cancelled
        let desc = error.errorDescription!
        #expect(desc.contains("cancelled"))
    }

    @Test("All errors conform to LocalizedError")
    func conformsToLocalizedError() {
        let errors: [LocalLLMError] = [
            .modelFileNotFound(URL(fileURLWithPath: "/a")),
            .downloadFailed(url: URL(string: "https://a.com")!, underlying: "x"),
            .modelLoadFailed("x"),
            .contextCreationFailed("x"),
            .tokenizationFailed("x"),
            .contextOverflow(promptTokens: 1, contextSize: 1),
            .generationFailed("x"),
            .decodeFailed(code: 0),
            .cancelled,
        ]
        for error in errors {
            #expect(error.errorDescription != nil)
            #expect(!error.errorDescription!.isEmpty)
        }
    }

    @Test("No leaked C type names in error descriptions")
    func noCTypeLeaks() {
        let errors: [LocalLLMError] = [
            .modelFileNotFound(URL(fileURLWithPath: "/a")),
            .downloadFailed(url: URL(string: "https://a.com")!, underlying: "network error"),
            .modelLoadFailed("failed"),
            .contextCreationFailed("failed"),
            .tokenizationFailed("failed"),
            .contextOverflow(promptTokens: 100, contextSize: 50),
            .generationFailed("failed"),
            .decodeFailed(code: -1),
            .cancelled,
        ]
        let cTypePatterns = ["llama_", "ggml_", "OpaquePointer", "UnsafeMutable"]
        for error in errors {
            let desc = error.errorDescription!
            for pattern in cTypePatterns {
                #expect(!desc.contains(pattern), "Error description should not contain '\(pattern)': \(desc)")
            }
        }
    }
}
