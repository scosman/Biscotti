import Foundation
import Testing

@testable import STTLabCore

@Suite("SHA256File tests")
struct SHA256FileTests {
    @Test func knownContentHash() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("STTLabCoreTests")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("sha256_test_\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }

        // SHA-256("abc") = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
        try "abc".data(using: .utf8)!.write(to: url)

        let hash = try SHA256File.hex(url: url)
        #expect(hash == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func emptyFileHash() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("STTLabCoreTests")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("sha256_empty_\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }

        try Data().write(to: url)
        let hash = try SHA256File.hex(url: url)
        // SHA-256 of empty input
        #expect(hash == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }
}
