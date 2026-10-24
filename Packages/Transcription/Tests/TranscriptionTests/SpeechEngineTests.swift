import AVFoundation
import Foundation
import Testing
import WhisperKit
@testable import Transcription

// MARK: - Method / engine mapping

@Suite("TranscriptionMethod and engine mapping")
struct MethodEngineMappingTests {
    @Test("v1 and v2 map to whisper engine")
    func whisperMethods() {
        #expect(TranscriptionMethod.v1.engine == .whisper)
        #expect(TranscriptionMethod.v2.engine == .whisper)
        #expect(TranscriptionMethod.current.engine == .whisper)
    }

    @Test("appleV1 maps to apple engine")
    func appleMethods() {
        #expect(TranscriptionMethod.appleV1.engine == .apple)
        #expect(TranscriptionMethod.appleV1.id == "apple-v1")
    }

    @Test("TranscriptionMethod Codable round-trip")
    func methodCodable() throws {
        let methods: [TranscriptionMethod] = [.v1, .v2, .appleV1]
        for method in methods {
            let data = try JSONEncoder().encode(method)
            let decoded = try JSONDecoder().decode(TranscriptionMethod.self, from: data)
            #expect(decoded == method)
            #expect(decoded.id == method.id)
        }
    }
}

// MARK: - TranscriptionConfig

@Suite("TranscriptionConfig")
struct TranscriptionConfigTests {
    @Test("whisper factory produces correct config")
    func whisperFactory() {
        let config = TranscriptionConfig.whisper()
        #expect(config.method == .current)
        #expect(config.locale == nil)
        #expect(config.engine == .whisper)
    }

    @Test("apple factory produces correct config")
    func appleFactory() {
        let config = TranscriptionConfig.apple(locale: "en_US")
        #expect(config.method == .appleV1)
        #expect(config.locale == "en_US")
        #expect(config.engine == .apple)
    }

    @Test("config Codable round-trip")
    func configCodable() throws {
        let configs: [TranscriptionConfig] = [
            .whisper(),
            .apple(locale: "en_US"),
            .apple(locale: "fr_FR")
        ]
        for config in configs {
            let data = try JSONEncoder().encode(config)
            let decoded = try JSONDecoder().decode(TranscriptionConfig.self, from: data)
            #expect(decoded == config)
        }
    }
}

// MARK: - ModelComponent

@Suite("ModelComponent")
struct ModelComponentTests {
    @Test("all contains both components")
    func allComponents() {
        let all: Set<ModelComponent> = .all
        #expect(all.contains(.whisper))
        #expect(all.contains(.speakerID))
        #expect(all.count == 2)
    }

    @Test("Codable round-trip")
    func componentCodable() throws {
        for component in ModelComponent.allCases {
            let data = try JSONEncoder().encode(component)
            let decoded = try JSONDecoder().decode(ModelComponent.self, from: data)
            #expect(decoded == component)
        }
    }
}

// MARK: - MethodResolver

@Suite("MethodResolver - apple-v1")
struct ResolverAppleTests {
    @Test("apple-v1 resolves to apple engine with subsegment and no language detection")
    func appleV1Settings() {
        let sixteenGB: UInt64 = 16 * 1024 * 1024 * 1024
        let settings = MethodResolver.resolve(.appleV1, physicalMemory: sixteenGB)

        #expect(settings.engine == .apple)
        #expect(settings.diarizationStrategy == .subsegment)
        #expect(settings.detectLanguage == false)
        #expect(settings.enableWordTimestamps == true)
        #expect(settings.sequentialLoading == false)
    }

    @Test("apple-v1 enables sequential loading on low RAM")
    func appleV1LowRAM() {
        let eightGB: UInt64 = 8 * 1024 * 1024 * 1024
        let settings = MethodResolver.resolve(.appleV1, physicalMemory: eightGB)

        #expect(settings.engine == .apple)
        #expect(settings.sequentialLoading == true)
    }

    @Test("whisper methods still resolve with engine .whisper")
    func whisperMethodsHaveEngine() {
        let sixteenGB: UInt64 = 16 * 1024 * 1024 * 1024
        let settingsV1 = MethodResolver.resolve(.v1, physicalMemory: sixteenGB)
        let settingsV2 = MethodResolver.resolve(.v2, physicalMemory: sixteenGB)

        #expect(settingsV1.engine == .whisper)
        #expect(settingsV2.engine == .whisper)
    }
}

// MARK: - XPCProcessRequest

@Suite("XPCProcessRequest")
struct XPCProcessRequestTests {
    @Test("decodes without config field (backward compatibility)")
    func decodesWithoutConfig() throws {
        // Simulate an old-format request without the config field.
        let json = """
        {"micPath":"/tmp/mic.wav","systemPath":"/tmp/sys.wav","customVocabulary":["test"]}
        """
        let data = Data(json.utf8)
        let request = try JSONDecoder().decode(XPCProcessRequest.self, from: data)

        #expect(request.micPath == "/tmp/mic.wav")
        #expect(request.systemPath == "/tmp/sys.wav")
        #expect(request.customVocabulary == ["test"])
        #expect(request.config == nil)
    }

    @Test("round-trips config through encode/decode")
    func roundTripsConfig() throws {
        let config = TranscriptionConfig.apple(locale: "en_US")
        let request = XPCProcessRequest(
            micPath: "/a", systemPath: "/b",
            customVocabulary: [], config: config
        )
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(XPCProcessRequest.self, from: data)

        #expect(decoded.config == config)
        #expect(decoded.config?.method == .appleV1)
        #expect(decoded.config?.locale == "en_US")
    }
}

// MARK: - XPCDownloadRequest

@Suite("XPCDownloadRequest")
struct XPCDownloadRequestTests {
    @Test("components encode and decode")
    func componentsCodable() throws {
        let request = XPCDownloadRequest(components: [.speakerID])
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(XPCDownloadRequest.self, from: data)

        #expect(decoded.componentSet == [.speakerID])
    }

    @Test("empty components decode to all")
    func emptyDecodesToAll() throws {
        let json = """
        {"components":[]}
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(XPCDownloadRequest.self, from: data)

        #expect(decoded.componentSet == .all)
    }

    @Test("all components round-trip")
    func allComponentsRoundTrip() throws {
        let request = XPCDownloadRequest(components: .all)
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(XPCDownloadRequest.self, from: data)

        #expect(decoded.componentSet == .all)
    }
}

// MARK: - Component presence and delete

@Suite("Component presence and delete")
struct ComponentPresenceTests {
    /// A unique test repo name that will never collide with real models.
    private static let testRepo = "__test_repo_\(UUID().uuidString)"
    private static let testModel = "test-model"

    /// The temp directory tree for a fake whisper model.
    private static var testModelDir: URL {
        ModelStorage.whisperModelDirectory(repo: testRepo, model: testModel)
    }

    /// Creates a fake `.mlmodelc` directory inside the test model directory
    /// so `whisperKitModelsPresent` returns true.
    private static func createFakeModel() throws {
        let mlmodelcDir = testModelDir.appendingPathComponent("fake.mlmodelc", isDirectory: true)
        try FileManager.default.createDirectory(
            at: mlmodelcDir, withIntermediateDirectories: true
        )
    }

    /// Removes the test repo directory and its parents up to (but not
    /// including) the models base directory.
    private static func cleanupTestRepo() {
        try? FileManager.default.removeItem(at: testModelDir)
        // Remove the parent repo directory (empty after model removal).
        let repoDir = testModelDir.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: repoDir)
    }

    @Test("componentPresent returns false when directory does not exist")
    func componentNotPresentForMissingDir() {
        // Use a fake repo name that will not exist on disk.
        let settings = ResolvedMethodSettings(
            engine: .whisper,
            sttModel: Self.testModel,
            sttModelRepo: Self.testRepo,
            enableWordTimestamps: true,
            detectLanguage: false,
            diarizationStrategy: .subsegment,
            sequentialLoading: false
        )

        let present = InProcessTranscriptionEngine.componentPresent(.whisper, settings: settings)
        #expect(present == false, "Should be false when the model directory does not exist")
    }

    @Test("componentPresent returns true when .mlmodelc exists")
    func componentPresentWhenModelExists() throws {
        defer { Self.cleanupTestRepo() }
        try Self.createFakeModel()

        let settings = ResolvedMethodSettings(
            engine: .whisper,
            sttModel: Self.testModel,
            sttModelRepo: Self.testRepo,
            enableWordTimestamps: true,
            detectLanguage: false,
            diarizationStrategy: .subsegment,
            sequentialLoading: false
        )

        let present = InProcessTranscriptionEngine.componentPresent(.whisper, settings: settings)
        #expect(present == true, "Should be true when .mlmodelc exists")
    }

    @Test("removeDirectory deletes whisper model but leaves sibling intact")
    func deleteWhisperLeavesSpeakerID() throws {
        defer { Self.cleanupTestRepo() }

        // Create a fake whisper model directory.
        try Self.createFakeModel()
        #expect(FileManager.default.fileExists(atPath: Self.testModelDir.path))

        // Delete it.
        try ModelStorage.removeDirectory(Self.testModelDir)
        #expect(
            !FileManager.default.fileExists(atPath: Self.testModelDir.path),
            "Model directory should be removed after delete"
        )
    }

    @Test("removeDirectory is a no-op when directory does not exist")
    func deleteNonexistentIsNoop() throws {
        let bogusURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("biscotti-test-\(UUID().uuidString)")

        // Should not throw.
        try ModelStorage.removeDirectory(bogusURL)
    }
}

// MARK: - AppleSpeechSupport

@Suite("AppleSpeechSupport")
struct AppleSpeechSupportTests {
    @Test("availability on macOS 15 returns requiresOSUpdate")
    func unavailableBelow26() {
        let availability = AppleSpeechSupport.availability()
        // CI runs on macOS 15. If somehow on 26+, the test is still valid.
        switch availability {
        case let .requiresOSUpdate(major):
            #expect(major < 26)
        case .available, .unavailable:
            // On macOS 26+ both are acceptable.
            break
        }
    }

    @Test("supportedLocales returns empty when unavailable")
    func noLocalesBelow26() async {
        let availability = AppleSpeechSupport.availability()
        guard case .requiresOSUpdate = availability else { return }
        let locales = await AppleSpeechSupport.supportedLocales()
        #expect(locales.isEmpty)
    }
}

// MARK: - engineUnavailable error mapping

@Suite("TranscriptionError - engineUnavailable")
struct EngineUnavailableErrorTests {
    @Test("engineUnavailable case exists and is equatable")
    func engineUnavailableEquatable() {
        let error1 = TranscriptionError.engineUnavailable("test")
        let error2 = TranscriptionError.engineUnavailable("test")
        let error3 = TranscriptionError.engineUnavailable("other")

        #expect(error1 == error2)
        #expect(error1 != error3)
    }
}

// MARK: - WAVWriter

@Suite("WAVWriter")
struct WAVWriterTests {
    @Test("writes and reads back a WAV file")
    func writeAndRead() throws {
        let samples: [Float] = Array(repeating: 0.5, count: 16000)
        let url = try WAVWriter.writeTemp(samples)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(FileManager.default.fileExists(atPath: url.path))

        let file = try AVAudioFile(forReading: url)
        #expect(file.length == 16000)
        #expect(file.fileFormat.sampleRate == 16000)
        #expect(file.fileFormat.channelCount == 1)
    }

    @Test("empty samples produce a zero-length file")
    func emptySamples() throws {
        let url = try WAVWriter.writeTemp([])
        defer { try? FileManager.default.removeItem(at: url) }

        let file = try AVAudioFile(forReading: url)
        #expect(file.length == 0)
    }
}
