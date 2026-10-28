import Foundation
import Testing
@testable import TranscriptionService

@Suite("PreparedModels")
@MainActor
struct PreparedModelsTests {
    @Test("prepared models are remembered for the same build only")
    func recordPersistsForTheSameBuildOnly() throws {
        let suite = "PreparedModelsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        PreparedModels(build: "b1", defaults: defaults).record(["live", "final"])

        #expect(PreparedModels(build: "b1", defaults: defaults).contains("live"))
        #expect(PreparedModels(build: "b1", defaults: defaults).contains("final"))
        #expect(!PreparedModels(build: "b2", defaults: defaults).contains("live"))
    }

    @Test("a rebuilt worker, a new build number or a macOS update gives a new build identity")
    func identityChangesWithBuildAndExecutable() throws {
        let app = try FakeAppBundle()
        defer { app.remove() }
        let bundle = try #require(Bundle(url: app.url))
        let first = PreparedModels.buildIdentity(of: bundle, osVersion: "15.6")

        #expect(PreparedModels.buildIdentity(of: bundle, osVersion: "15.6") == first)
        #expect(PreparedModels.buildIdentity(of: bundle, osVersion: "15.7") != first)
        try app.touchWorker(addingSeconds: 10)
        #expect(PreparedModels.buildIdentity(of: bundle, osVersion: "15.6") != first)
        #expect(first.hasPrefix("1.0|7|15.6|"))
    }
}

/// An app bundle on disk with one XPC service, as the build identity reads it.
private struct FakeAppBundle {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("PreparedModelsTests-\(UUID().uuidString).app")
        try Self.makeBundle(at: url, executable: "App", extra: ["CFBundleShortVersionString": "1.0", "CFBundleVersion": "7"])
        try Self.makeBundle(at: workerURL, executable: "Worker", extra: [:])
    }

    var workerURL: URL {
        url.appendingPathComponent("Contents/XPCServices/Worker.xpc")
    }

    func touchWorker(addingSeconds seconds: TimeInterval) throws {
        let executable = workerURL.appendingPathComponent("Contents/MacOS/Worker").path
        let written = try FileManager.default.attributesOfItem(atPath: executable)[.modificationDate] as? Date ?? Date()
        try FileManager.default.setAttributes([.modificationDate: written.addingTimeInterval(seconds)], ofItemAtPath: executable)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    private static func makeBundle(at url: URL, executable: String, extra: [String: String]) throws {
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let info = ["CFBundleExecutable": executable, "CFBundleIdentifier": "test.\(executable)", "CFBundlePackageType": "APPL"]
            .merging(extra) { $1 }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try Data("#!/bin/sh\n".utf8).write(to: contents.appendingPathComponent("MacOS/\(executable)"))
    }
}
