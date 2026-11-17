import Foundation
import Testing
@testable import ImportUI

@Suite("PromisedFile")
struct PromisedFileTests {
    @Test("resolves with URL when no error")
    func resolveSuccess() async throws {
        let file = PromisedFile()
        let url = URL(fileURLWithPath: "/tmp/test.m4a")
        file.resolve(url: url, error: nil)
        let result = try await file.value
        #expect(result == url)
    }

    @Test("resolves with error when only error provided")
    func resolveErrorOnly() async {
        let file = PromisedFile()
        file.resolve(url: nil, error: PromisedFileError.noFileDelivered)
        await #expect(throws: PromisedFileError.self) {
            try await file.value
        }
    }

    @Test("error takes priority when both URL and error are present")
    func errorTakesPriorityOverURL() async {
        let file = PromisedFile()
        let url = URL(fileURLWithPath: "/tmp/test.m4a")
        file.resolve(url: url, error: PromisedFileError.noFileDelivered)
        await #expect(throws: PromisedFileError.self) {
            try await file.value
        }
    }

    @Test("resolves with noFileDelivered when both nil")
    func bothNil() async {
        let file = PromisedFile()
        file.resolve(url: nil, error: nil)
        await #expect(throws: PromisedFileError.noFileDelivered) {
            try await file.value
        }
    }

    @Test("await before resolve succeeds")
    func awaitBeforeResolve() async throws {
        let file = PromisedFile()
        let url = URL(fileURLWithPath: "/tmp/test.m4a")
        Task {
            file.resolve(url: url, error: nil)
        }
        let result = try await file.value
        #expect(result == url)
    }
}
