import Foundation
import Testing

@testable import STTLabCore

@Suite("BundleLoader tests")
struct BundleLoaderTests {
    private func tempBundleDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("STTLabCoreTests")
            .appendingPathComponent("bundle_\(UUID().uuidString)")
    }

    private func createValidBundle(at bundleURL: URL, meetings: [String] = ["m01", "m02"]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let manifest = BundleManifest(meetings: meetings)
        try JSONFiles.write(manifest, to: bundleURL.appendingPathComponent("manifest.json"))

        for mid in meetings {
            let meetingDir = bundleURL.appendingPathComponent("meetings/\(mid)")
            try fm.createDirectory(at: meetingDir, withIntermediateDirectories: true)

            let meta = MeetingMeta(
                meetingID: mid,
                durationSeconds: 1800,
                speakerCount: 2,
                transcriptLanguage: "en",
                appleLocale: "en_US",
                audioSHA256: "abc123"
            )
            try JSONFiles.write(meta, to: meetingDir.appendingPathComponent("meta.json"))

            // Write a small audio file placeholder
            try Data([0x00]).write(to: meetingDir.appendingPathComponent("audio.wav"))
        }
    }

    @Test func loadValidBundle() throws {
        let bundleURL = tempBundleDir()
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        try createValidBundle(at: bundleURL)
        let loaded = try BundleLoader.load(from: bundleURL)

        #expect(loaded.manifest.meetings == ["m01", "m02"])
        #expect(loaded.metas.count == 2)
        #expect(loaded.metas[0].meetingID == "m01")
        #expect(loaded.metas[1].meetingID == "m02")
    }

    @Test func rejectsWrongSchemaVersion() throws {
        let bundleURL = tempBundleDir()
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let fm = FileManager.default
        try fm.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        var manifest = BundleManifest(meetings: ["m01"])
        manifest.schemaVersion = 999
        try JSONFiles.write(manifest, to: bundleURL.appendingPathComponent("manifest.json"))

        #expect(throws: BundleLoaderError.bundleVersionMismatch(found: 999, expected: SchemaVersions.bundle)) {
            try BundleLoader.load(from: bundleURL)
        }
    }

    @Test func rejectsMissingAudioFile() throws {
        let bundleURL = tempBundleDir()
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let fm = FileManager.default
        try fm.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let manifest = BundleManifest(meetings: ["m01"])
        try JSONFiles.write(manifest, to: bundleURL.appendingPathComponent("manifest.json"))

        let meetingDir = bundleURL.appendingPathComponent("meetings/m01")
        try fm.createDirectory(at: meetingDir, withIntermediateDirectories: true)
        let meta = MeetingMeta(
            meetingID: "m01", durationSeconds: 1800, speakerCount: 2,
            transcriptLanguage: "en", appleLocale: "en_US", audioSHA256: "abc"
        )
        try JSONFiles.write(meta, to: meetingDir.appendingPathComponent("meta.json"))
        // No audio.wav written

        #expect {
            try BundleLoader.load(from: bundleURL)
        } throws: { error in
            guard let loaderError = error as? BundleLoaderError,
                  case let .audioNotFound(mid, _) = loaderError
            else { return false }
            return mid == "m01"
        }
    }

    @Test func rejectsMissingManifest() throws {
        let bundleURL = tempBundleDir()
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        #expect {
            try BundleLoader.load(from: bundleURL)
        } throws: { error in
            guard let loaderError = error as? BundleLoaderError,
                  case .manifestNotFound = loaderError
            else { return false }
            return true
        }
    }

    @Test func rejectsMissingMeta() throws {
        let bundleURL = tempBundleDir()
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let fm = FileManager.default
        try fm.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let manifest = BundleManifest(meetings: ["m01"])
        try JSONFiles.write(manifest, to: bundleURL.appendingPathComponent("manifest.json"))

        // Create meeting dir without meta.json
        let meetingDir = bundleURL.appendingPathComponent("meetings/m01")
        try fm.createDirectory(at: meetingDir, withIntermediateDirectories: true)

        #expect(throws: BundleLoaderError.metaNotFound(meetingID: "m01")) {
            try BundleLoader.load(from: bundleURL)
        }
    }
}
