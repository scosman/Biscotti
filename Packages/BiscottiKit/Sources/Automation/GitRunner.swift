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
            let first: GitResult??
            do {
                first = try await group.next()
            } catch {
                job.terminate()
                throw error
            }
            guard let first, let result = first else {
                // Kill git and anything it started (hooks), so the run
                // ends now instead of when a hook lets go of the output.
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

/// Wraps a configured `Process` so it can be awaited. Output is collected as
/// it arrives rather than read to end of file, because a hook that git
/// started can hold the pipe open after git itself has exited. `Process` is
/// not `Sendable`; this box is safe because the process is started once and
/// all shared state is behind `lock`.
private final class ProcessJob: @unchecked Sendable {
    private let process: Process
    private let pipe = Pipe()
    private let lock = NSLock()
    private var output = Data()
    private var continuation: CheckedContinuation<GitResult, Error>?
    private var reachedEnd = false
    private var exited = false

    /// How long to keep reading after git exits, for output still in the pipe.
    private static let drainGrace: DispatchTimeInterval = .seconds(2)

    init(process: Process) {
        self.process = process
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
    }

    func runToCompletion() async throws -> GitResult {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { self.continuation = continuation }
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let chunk = handle.availableData
                guard let self else { return }
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    lock.withLock { self.reachedEnd = true }
                    finishIfDone()
                } else {
                    lock.withLock { self.output.append(chunk) }
                }
            }
            process.terminationHandler = { [weak self] _ in
                guard let self else { return }
                lock.withLock { exited = true }
                finishIfDone()
                // A hook may still hold the pipe: don't wait for it forever.
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.drainGrace) {
                    self.finish()
                }
            }
            do {
                try process.run()
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                let pending = lock.withLock { () -> CheckedContinuation<GitResult, Error>? in
                    defer { self.continuation = nil }
                    return self.continuation
                }
                pending?.resume(throwing: error)
            }
        }
    }

    private func finishIfDone() {
        let done = lock.withLock { exited && reachedEnd }
        if done { finish() }
    }

    /// Resumes the caller once, with whatever output arrived.
    private func finish() {
        let (pending, data) = lock.withLock { () -> (CheckedContinuation<GitResult, Error>?, Data) in
            defer { continuation = nil }
            return (continuation, output)
        }
        guard let pending else { return }
        pipe.fileHandleForReading.readabilityHandler = nil
        let text = String(bytes: data, encoding: .utf8) ?? ""
        pending.resume(returning: GitResult(exitCode: process.terminationStatus, output: text))
    }

    /// Force-kills git and every process it started. SIGKILL rather than
    /// `terminate()` (SIGTERM): a child spawned from a dispatch worker thread
    /// can inherit a signal mask that blocks SIGTERM, and SIGKILL cannot be
    /// blocked. The tree is collected first, so children are found before
    /// their parent dies and they are re-parented.
    func terminate() {
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        for child in Self.descendants(of: pid) {
            kill(child, SIGKILL)
        }
        if process.isRunning {
            kill(pid, SIGKILL)
        }
    }

    static func descendants(of root: pid_t) -> [pid_t] {
        var found: [pid_t] = []
        var queue = [root]
        while let current = queue.popLast() {
            var children = [pid_t](repeating: 0, count: 256)
            let count = children.withUnsafeMutableBytes { buffer in
                proc_listchildpids(current, buffer.baseAddress, Int32(buffer.count))
            }
            guard count > 0 else { continue }
            for child in children.prefix(min(Int(count), children.count)) where child > 0 {
                found.append(child)
                queue.append(child)
            }
        }
        return found
    }
}
