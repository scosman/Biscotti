import Foundation
import Testing
@testable import LocalLLM

@Suite("LocalLLMError")
struct ErrorTests {
    @Test("modelFileNotFound has descriptive message")
    func modelFileNotFound() throws {
        let error = LocalLLMError.modelFileNotFound(URL(fileURLWithPath: "/path/to/model.gguf"))
        let desc = try #require(error.errorDescription)
        #expect(desc.contains("Model file not found"))
        #expect(desc.contains("/path/to/model.gguf"))
    }

    @Test("downloadFailed includes URL and underlying reason")
    func downloadFailed() throws {
        let error = try LocalLLMError.downloadFailed(
            url: #require(URL(string: "https://example.com/model.gguf")),
            underlying: "HTTP 404"
        )
        let desc = try #require(error.errorDescription)
        #expect(desc.contains("Download failed"))
        #expect(desc.contains("example.com"))
        #expect(desc.contains("HTTP 404"))
    }

    @Test("modelLoadFailed includes detail")
    func modelLoadFailed() throws {
        let error = LocalLLMError.modelLoadFailed("null pointer")
        let desc = try #require(error.errorDescription)
        #expect(desc.contains("Failed to load model"))
        #expect(desc.contains("null pointer"))
    }

    @Test("contextCreationFailed includes detail")
    func contextCreationFailed() throws {
        let error = LocalLLMError.contextCreationFailed("out of memory")
        let desc = try #require(error.errorDescription)
        #expect(desc.contains("Failed to create context"))
        #expect(desc.contains("out of memory"))
    }

    @Test("tokenizationFailed includes detail")
    func tokenizationFailed() throws {
        let error = LocalLLMError.tokenizationFailed("buffer overflow")
        let desc = try #require(error.errorDescription)
        #expect(desc.contains("Tokenization failed"))
        #expect(desc.contains("buffer overflow"))
    }

    @Test("contextOverflow includes token counts")
    func contextOverflow() throws {
        let error = LocalLLMError.contextOverflow(promptTokens: 33000, contextSize: 32768)
        let desc = try #require(error.errorDescription)
        #expect(desc.contains("33000"))
        #expect(desc.contains("32768"))
        #expect(desc.contains("exceeds"))
    }

    @Test("generationFailed includes detail")
    func generationFailed() throws {
        let error = LocalLLMError.generationFailed("decode error")
        let desc = try #require(error.errorDescription)
        #expect(desc.contains("Generation failed"))
    }

    @Test("decodeFailed includes error code")
    func decodeFailed() throws {
        let error = LocalLLMError.decodeFailed(code: -1)
        let desc = try #require(error.errorDescription)
        #expect(desc.contains("-1"))
    }

    @Test("cancelled has description")
    func cancelled() throws {
        let error = LocalLLMError.cancelled
        let desc = try #require(error.errorDescription)
        #expect(desc.contains("cancelled"))
    }

    @Test("All errors conform to LocalizedError")
    func conformsToLocalizedError() throws {
        let errors: [LocalLLMError] = try [
            .modelFileNotFound(URL(fileURLWithPath: "/a")),
            .downloadFailed(url: #require(URL(string: "https://a.com")), underlying: "x"),
            .modelLoadFailed("x"),
            .contextCreationFailed("x"),
            .tokenizationFailed("x"),
            .contextOverflow(promptTokens: 1, contextSize: 1),
            .generationFailed("x"),
            .decodeFailed(code: 0),
            .cancelled
        ]
        for error in errors {
            #expect(error.errorDescription != nil)
            #expect(try !#require(error.errorDescription?.isEmpty))
        }
    }

    @Test("No leaked C type names in error descriptions")
    func noCTypeLeaks() throws {
        let errors: [LocalLLMError] = try [
            .modelFileNotFound(URL(fileURLWithPath: "/a")),
            .downloadFailed(url: #require(URL(string: "https://a.com")), underlying: "network error"),
            .modelLoadFailed("failed"),
            .contextCreationFailed("failed"),
            .tokenizationFailed("failed"),
            .contextOverflow(promptTokens: 100, contextSize: 50),
            .generationFailed("failed"),
            .decodeFailed(code: -1),
            .cancelled
        ]
        let cTypePatterns = ["llama_", "ggml_", "OpaquePointer", "UnsafeMutable"]
        for error in errors {
            let desc = try #require(error.errorDescription)
            for pattern in cTypePatterns {
                #expect(!desc.contains(pattern), "Error description should not contain '\(pattern)': \(desc)")
            }
        }
    }
}
