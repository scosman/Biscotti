import AppKit
import AudioImport
import Foundation
import Testing
@testable import ImportUI

@Suite("PasteboardClassifier.supportedFlags")
struct PasteboardSupportedFlagsTests {
    @Test("file URL with supported extension is supported")
    func fileURLSupported() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PBTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let wav = dir.appendingPathComponent("song.wav")
        FileManager.default.createFile(atPath: wav.path, contents: nil)

        let descriptors = [DraggedItemDescriptor(kind: .file(wav))]
        let flags = PasteboardClassifier.supportedFlags(descriptors)
        #expect(flags == [true])
    }

    @Test("file URL with unsupported extension is unsupported")
    func fileURLUnsupported() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PBTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let pdf = dir.appendingPathComponent("doc.pdf")
        FileManager.default.createFile(atPath: pdf.path, contents: nil)

        let descriptors = [DraggedItemDescriptor(kind: .file(pdf))]
        let flags = PasteboardClassifier.supportedFlags(descriptors)
        #expect(flags == [false])
    }

    @Test("directory URL is unsupported")
    func directoryUnsupported() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PBTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let descriptors = [DraggedItemDescriptor(kind: .file(dir))]
        let flags = PasteboardClassifier.supportedFlags(descriptors)
        #expect(flags == [false])
    }

    @Test("promise with audio type identifier is supported")
    func promiseAudioSupported() {
        let descriptors = [
            DraggedItemDescriptor(
                kind: .promise(typeIdentifier: "public.mp3", index: 0)
            )
        ]
        let flags = PasteboardClassifier.supportedFlags(descriptors)
        #expect(flags == [true])
    }

    @Test("promise with com.apple.m4a-audio is supported")
    func promiseM4ASupported() {
        let descriptors = [
            DraggedItemDescriptor(
                kind: .promise(
                    typeIdentifier: "com.apple.m4a-audio", index: 0
                )
            )
        ]
        let flags = PasteboardClassifier.supportedFlags(descriptors)
        #expect(flags == [true])
    }

    @Test("promise with PDF type identifier is unsupported")
    func promisePDFUnsupported() {
        let descriptors = [
            DraggedItemDescriptor(
                kind: .promise(
                    typeIdentifier: "com.adobe.pdf", index: 0
                )
            )
        ]
        let flags = PasteboardClassifier.supportedFlags(descriptors)
        #expect(flags == [false])
    }

    @Test("promise with nil type identifier is unsupported")
    func promiseNilTypeUnsupported() {
        let descriptors = [
            DraggedItemDescriptor(
                kind: .promise(typeIdentifier: nil, index: 0)
            )
        ]
        let flags = PasteboardClassifier.supportedFlags(descriptors)
        #expect(flags == [false])
    }

    @Test("mixed descriptors produce correct flags")
    func mixedDescriptors() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PBTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let wav = dir.appendingPathComponent("audio.wav")
        FileManager.default.createFile(atPath: wav.path, contents: nil)
        let pdf = dir.appendingPathComponent("report.pdf")
        FileManager.default.createFile(atPath: pdf.path, contents: nil)

        let descriptors = [
            DraggedItemDescriptor(kind: .file(wav)),
            DraggedItemDescriptor(kind: .file(pdf)),
            DraggedItemDescriptor(
                kind: .promise(
                    typeIdentifier: "com.apple.m4a-audio", index: 0
                )
            )
        ]
        let flags = PasteboardClassifier.supportedFlags(descriptors)
        #expect(flags == [true, false, true])
    }

    @Test("empty descriptors produce empty flags")
    func emptyDescriptors() {
        let flags = PasteboardClassifier.supportedFlags([])
        #expect(flags.isEmpty)
    }
}

@Suite("PasteboardClassifier.describe with real pasteboard")
struct PasteboardDescribeTests {
    @Test("file URL item produces file descriptor")
    @MainActor
    func fileURLItem() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PBTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let wav = dir.appendingPathComponent("test.wav")
        FileManager.default.createFile(atPath: wav.path, contents: nil)

        let pasteboard = NSPasteboard(name: .init("test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()

        let item = NSPasteboardItem()
        item.setString(wav.absoluteString, forType: .fileURL)
        pasteboard.writeObjects([item])

        let descriptors = PasteboardClassifier.describe(pasteboard)
        #expect(descriptors.count == 1)
        if case let .file(url) = descriptors[0].kind {
            #expect(url == wav)
        } else {
            Issue.record("Expected file descriptor, got \(descriptors[0])")
        }
    }

    @Test("plain string item is skipped")
    @MainActor
    func plainStringSkipped() {
        let pasteboard = NSPasteboard(name: .init("test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()

        let item = NSPasteboardItem()
        item.setString("Just a string", forType: .string)
        pasteboard.writeObjects([item])

        let descriptors = PasteboardClassifier.describe(pasteboard)
        #expect(descriptors.isEmpty)
    }

    @Test("multiple file URLs produce multiple descriptors in order")
    @MainActor
    func multipleFileURLs() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PBTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let audioURL = dir.appendingPathComponent("a.mp3")
        FileManager.default.createFile(
            atPath: audioURL.path, contents: nil
        )
        let docURL = dir.appendingPathComponent("b.pdf")
        FileManager.default.createFile(
            atPath: docURL.path, contents: nil
        )

        let pasteboard = NSPasteboard(name: .init("test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()

        let item1 = NSPasteboardItem()
        item1.setString(audioURL.absoluteString, forType: .fileURL)
        let item2 = NSPasteboardItem()
        item2.setString(docURL.absoluteString, forType: .fileURL)
        pasteboard.writeObjects([item1, item2])

        let descriptors = PasteboardClassifier.describe(pasteboard)
        #expect(descriptors.count == 2)
        if case let .file(url1) = descriptors[0].kind {
            #expect(url1 == audioURL)
        }
        if case let .file(url2) = descriptors[1].kind {
            #expect(url2 == docURL)
        }
    }
}
