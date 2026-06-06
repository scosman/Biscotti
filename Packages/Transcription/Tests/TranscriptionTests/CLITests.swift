import Foundation
import Testing
@testable import transcribe_cli
@testable import Transcription

// MARK: - Capturing output writer for tests

/// A test double that captures stdout/stderr writes for assertion.
final class CapturingOutputWriter: OutputWriter, @unchecked Sendable {
    private let lock = NSLock()
    private var _stdoutLines: [String] = []
    private var _stderrLines: [String] = []
    private var _stderrInline: [String] = []

    var stdoutLines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _stdoutLines
    }

    var stderrLines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _stderrLines
    }

    /// Inline stderr writes (no trailing newline), captured separately.
    var stderrInlineWrites: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _stderrInline
    }

    var stdoutText: String {
        stdoutLines.joined(separator: "\n")
    }

    var stderrText: String {
        stderrLines.joined(separator: "\n")
    }

    func writeStdout(_ text: String) {
        lock.lock()
        _stdoutLines.append(text)
        lock.unlock()
    }

    func writeStderr(_ text: String) {
        lock.lock()
        _stderrLines.append(text)
        lock.unlock()
    }

    func writeStderrInline(_ text: String) {
        lock.lock()
        _stderrInline.append(text)
        lock.unlock()
    }
}

// MARK: - Argument parsing tests

@Suite("CLI argument parsing")
struct CLIArgumentParsingTests {
    @Test("Parses --mic, --system, --merged paths")
    func argumentParsingPaths() throws {
        let cli = try TranscribeCLI.parse([
            "--mic", "/path/to/mic.wav",
            "--system", "/path/to/system.wav",
            "--merged", "/path/to/merged.wav"
        ])
        #expect(cli.mic == "/path/to/mic.wav")
        #expect(cli.system == "/path/to/system.wav")
        #expect(cli.merged == "/path/to/merged.wav")
    }

    @Test("Parses --model flag")
    func argumentParsingModel() throws {
        let cli = try TranscribeCLI.parse([
            "--mic", "/audio.wav",
            "--model", "large-v3_turbo_1307MB"
        ])
        #expect(cli.model == "large-v3_turbo_1307MB")
    }

    @Test("Parses --vocab comma-separated list")
    func argumentParsingVocab() throws {
        let cli = try TranscribeCLI.parse([
            "--mic", "/audio.wav",
            "--vocab", "Biscotti,WhisperKit,CoreML"
        ])
        #expect(cli.vocab == "Biscotti,WhisperKit,CoreML")
    }

    @Test("Parses --json flag")
    func argumentParsingJsonFlag() throws {
        let cli = try TranscribeCLI.parse([
            "--mic", "/audio.wav",
            "--json"
        ])
        #expect(cli.json == true)
    }

    @Test("Default values when flags are omitted")
    func argumentParsingDefaultValues() throws {
        let cli = try TranscribeCLI.parse(["--mic", "/audio.wav"])
        #expect(cli.model == nil)
        #expect(cli.vocab == nil)
        #expect(cli.json == false)
    }

    @Test("Validation rejects zero audio paths")
    func validationRequiresAtLeastOneAudioPath() {
        // ArgumentParser's parse() calls validate(), so parse itself throws
        // when no audio paths are provided.
        #expect(throws: (any Error).self) {
            _ = try TranscribeCLI.parse([])
        }
    }

    @Test("Validation passes with only --mic")
    func validationPassesWithMicOnly() throws {
        let cli = try TranscribeCLI.parse(["--mic", "/audio.wav"])
        try cli.validate() // should not throw
    }

    @Test("Validation passes with only --merged")
    func validationPassesWithMergedOnly() throws {
        let cli = try TranscribeCLI.parse(["--merged", "/merged.wav"])
        try cli.validate() // should not throw
    }
}

// MARK: - Vocab parsing tests

@Suite("Vocab parsing helper")
struct VocabParsingTests {
    @Test("Parses comma-separated vocab")
    func parsesCommaList() {
        let terms = parseVocab("Biscotti,WhisperKit,CoreML")
        #expect(terms == ["Biscotti", "WhisperKit", "CoreML"])
    }

    @Test("Trims whitespace around terms")
    func trimsWhitespace() {
        let terms = parseVocab("  foo , bar , baz  ")
        #expect(terms == ["foo", "bar", "baz"])
    }

    @Test("Returns empty for nil input")
    func nilInput() {
        let terms = parseVocab(nil)
        #expect(terms.isEmpty)
    }

    @Test("Returns empty for empty string")
    func emptyString() {
        let terms = parseVocab("")
        #expect(terms.isEmpty)
    }
}

// MARK: - Config building tests

@Suite("Config building helper")
struct ConfigBuildingTests {
    @Test("Uses specified model when provided")
    func specifiedModel() {
        let config = buildConfig(model: "large-v3_turbo_1307MB")
        #expect(config.sttModel == "large-v3_turbo_1307MB")
    }

    @Test("Uses RAM-aware default when model is nil")
    func defaultModel() {
        let config = buildConfig(model: nil)
        // ramAware() picks based on physical memory; just verify it's non-empty
        #expect(!config.sttModel.isEmpty)
    }
}
