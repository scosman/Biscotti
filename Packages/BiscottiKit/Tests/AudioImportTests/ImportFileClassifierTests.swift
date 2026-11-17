import Foundation
import Testing
import UniformTypeIdentifiers
@testable import AudioImport

@Suite("ImportFileClassifier")
struct ImportFileClassifierTests {
    // MARK: - UTType classification

    @Test("audio types are supported")
    func audioTypes() {
        #expect(ImportFileClassifier.isSupported(.wav))
        #expect(ImportFileClassifier.isSupported(.mp3))
        #expect(ImportFileClassifier.isSupported(.aiff))
        #expect(ImportFileClassifier.isSupported(.mpeg4Audio)) // .m4a
        #expect(ImportFileClassifier.isSupported(.audio))
    }

    @Test("audiovisual types are supported")
    func audiovisualTypes() {
        #expect(ImportFileClassifier.isSupported(.mpeg4Movie))
        #expect(ImportFileClassifier.isSupported(.quickTimeMovie))
        #expect(ImportFileClassifier.isSupported(.movie))
    }

    @Test("non-audio types are not supported")
    func unsupportedTypes() {
        #expect(!ImportFileClassifier.isSupported(.pdf))
        #expect(!ImportFileClassifier.isSupported(.plainText))
        #expect(!ImportFileClassifier.isSupported(.png))
        #expect(!ImportFileClassifier.isSupported(.folder))
        #expect(!ImportFileClassifier.isSupported(.data))
    }

    // MARK: - File URL classification

    @Test("file URL with .wav extension is supported")
    func fileURLWav() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID()).wav")
        FileManager.default.createFile(atPath: url.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(ImportFileClassifier.isSupported(fileURL: url))
    }

    @Test("file URL with .txt extension is not supported")
    func fileURLTxt() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID()).txt")
        FileManager.default.createFile(atPath: url.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(!ImportFileClassifier.isSupported(fileURL: url))
    }

    @Test("directory is not supported")
    func directory() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dir-\(UUID())")
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(!ImportFileClassifier.isSupported(fileURL: url))
    }

    // MARK: - Type identifier

    @Test("type identifier classification")
    func typeIdentifier() {
        #expect(ImportFileClassifier.isSupported(typeIdentifier: "public.mp3"))
        #expect(ImportFileClassifier.isSupported(
            typeIdentifier: "com.apple.m4a-audio"
        ))
        #expect(!ImportFileClassifier.isSupported(
            typeIdentifier: "public.plain-text"
        ))
        #expect(!ImportFileClassifier.isSupported(
            typeIdentifier: "com.invalid.nonexistent"
        ))
    }

    // MARK: - Allowed content types

    @Test("allowedContentTypes contains audio and audiovisualContent")
    func allowedContentTypes() {
        let types = ImportFileClassifier.allowedContentTypes
        #expect(types.contains(.audio))
        #expect(types.contains(.audiovisualContent))
    }
}
