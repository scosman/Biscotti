import Foundation
import Testing

@testable import STTLabCore

@Suite("ErrorInfo tests")
struct ErrorInfoTests {
    @Test func initFromNSError() {
        let nsError = NSError(
            domain: "TestDomain",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "Something went wrong"]
        )
        let info = ErrorInfo(nsError)

        #expect(info.domain == "TestDomain")
        #expect(info.code == 42)
        #expect(info.description == "Something went wrong")
        #expect(info.debugDescription.contains("TestDomain"))
    }

    @Test func initFromSwiftError() {
        enum TestError: Error, LocalizedError {
            case badInput
            var errorDescription: String? { "Bad input provided" }
        }

        let info = ErrorInfo(TestError.badInput)
        #expect(info.description == "Bad input provided")
        #expect(info.debugDescription.contains("badInput"))
    }
}
