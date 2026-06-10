import Foundation
import Testing
@testable import transcribe_cli
@testable import Transcription

// MARK: - Capturing output writer for tests

/// A test double that captures stdout/stderr writes for assertion.
/// Shared across the CLI test suites (also used by CLIOutputTests).
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
    @Test("Parses --mic and --system paths")
    func argumentParsingPaths() throws {
        let cli = try TranscribeCLI.parse([
            "--mic", "/path/to/mic.wav",
            "--system", "/path/to/system.wav"
        ])
        #expect(cli.mic == "/path/to/mic.wav")
        #expect(cli.system == "/path/to/system.wav")
    }

    @Test("Parses --vocab comma-separated list")
    func argumentParsingVocab() throws {
        let cli = try TranscribeCLI.parse([
            "--mic", "/mic.wav",
            "--system", "/system.wav",
            "--vocab", "Biscotti,WhisperKit,CoreML"
        ])
        #expect(cli.vocab == "Biscotti,WhisperKit,CoreML")
    }

    @Test("Parses --json flag")
    func argumentParsingJsonFlag() throws {
        let cli = try TranscribeCLI.parse([
            "--mic", "/mic.wav",
            "--system", "/system.wav",
            "--json"
        ])
        #expect(cli.json == true)
    }

    @Test("Default values when optional flags are omitted")
    func argumentParsingDefaultValues() throws {
        let cli = try TranscribeCLI.parse([
            "--mic", "/mic.wav",
            "--system", "/system.wav"
        ])
        #expect(cli.vocab == nil)
        #expect(cli.json == false)
    }

    @Test("Parsing fails when --system is missing")
    func requiresSystemPath() {
        #expect(throws: (any Error).self) {
            _ = try TranscribeCLI.parse(["--mic", "/mic.wav"])
        }
    }

    @Test("Parsing fails when --mic is missing")
    func requiresMicPath() {
        #expect(throws: (any Error).self) {
            _ = try TranscribeCLI.parse(["--system", "/system.wav"])
        }
    }

    @Test("Parsing fails with no audio paths")
    func validationRequiresAudioPaths() {
        #expect(throws: (any Error).self) {
            _ = try TranscribeCLI.parse([])
        }
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
