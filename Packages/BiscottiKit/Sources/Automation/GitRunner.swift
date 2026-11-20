import Foundation

/// Output of one git invocation.
public struct GitResult: Sendable, Equatable {
    public let exitCode: Int32
    public let output: String

    public init(exitCode: Int32, output: String) {
        self.exitCode = exitCode
        self.output = output
    }
}

/// Seam over running git, so tests can substitute a fake.
public protocol GitRunning: Sendable {
    func run(_ arguments: [String], in directory: URL) async throws -> GitResult
}

public enum GitRunnerError: Error, Equatable, LocalizedError {
    case gitNotFound
    case timedOut(String)

    public var errorDescription: String? {
        switch self {
        case .gitNotFound:
            "git was not found. Install the Xcode Command Line Tools (xcode-select --install)."
        case let .timedOut(command):
            "git \(command) did not finish within the time limit."
        }
    }
}

/// Runs the system git binary with prompts disabled, so a push that needs
/// credentials fails fast instead of hanging the export.
public struct ProcessGitRunner: GitRunning {
    public let executable: URL
    public let timeout: Duration

    public init(executable: URL? = nil, timeout: Duration = .seconds(60)) {
        self.executable = executable ?? Self.locateGit()
        self.timeout = timeout
    }

    public func run(_ arguments: [String], in directory: URL) async throws -> GitResult {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw GitRunnerError.gitNotFound
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-C", directory.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_ASKPASS"] = "/usr/bin/true"
        process.environment = environment

        let job = ProcessJob(process: process)
        let limit = timeout
        return try await withThrowingTaskGroup(of: GitResult?.self) { group in
            group.addTask { try await job.runToCompletion() }
            group.addTask {
                try await Task.sleep(for: limit)
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let result = first else {
                job.terminate()
                throw GitRunnerError.timedOut(arguments.first ?? "")
            }
            return result
        }
    }

    static func locateGit() -> URL {
        let candidates = ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"]
        let found = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        return URL(fileURLWithPath: found ?? "/usr/bin/git")
    }
}

/// Wraps a configured `Process` so it can be run off the cooperative thread
/// pool. `Process` is not `Sendable`; this box is safe because the process is
/// only started once, from one queue, and `terminate()` is thread-safe.
private final class ProcessJob: @unchecked Sendable {
    private let process: Process
    private let pipe = Pipe()

    init(process: Process) {
        self.process = process
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
    }

    func runToCompletion() async throws -> GitResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    try self.process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                // Drain before waiting so a large output can't fill the pipe and block git.
                let data = self.pipe.fileHandleForReading.readDataToEndOfFile()
                self.process.waitUntilExit()
                let text = String(bytes: data, encoding: .utf8) ?? ""
                continuation.resume(returning: GitResult(exitCode: self.process.terminationStatus, output: text))
            }
        }
    }

    /// Force-kills the process. SIGKILL rather than `terminate()` (SIGTERM):
    /// a child spawned from a dispatch worker thread can inherit a signal
    /// mask that blocks SIGTERM, and SIGKILL cannot be blocked.
    func terminate() {
        let pid = process.processIdentifier
        if process.isRunning, pid > 0 {
            kill(pid, SIGKILL)
        }
    }
}
