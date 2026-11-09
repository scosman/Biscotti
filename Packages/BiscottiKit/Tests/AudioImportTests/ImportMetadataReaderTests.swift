import Foundation
import Testing
@testable import AudioImport

@Suite("ImportMetadataReader")
struct ImportMetadataReaderTests {
    @Test("missing file returns nil")
    func missingFile() async {
        let reader = AVFoundationMetadataReader()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent-\(UUID()).wav")

        let date = await reader.meetingDate(for: url)
        #expect(date == nil)
    }

    @Test("file with no embedded metadata uses modification date")
    func noEmbeddedMetadata() async throws {
        let reader = AVFoundationMetadataReader()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plain-\(UUID()).wav")
        // Write minimal data so the file exists.
        try Data(repeating: 0x00, count: 64).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let date = await reader.meetingDate(for: url)
        // Should return the modification date (just written).
        #expect(date != nil)
        if let date {
            let age = Date().timeIntervalSince(date)
            #expect(age < 60) // Created within the last minute.
        }
    }
}
