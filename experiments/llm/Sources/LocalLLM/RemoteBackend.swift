import Foundation
import os

/// Out-of-process `ServiceBackend` that spawns a child `localllm-service` process
/// and communicates via framed-JSON over stdin/stdout pipes.
///
/// The child process loads the model and serves requests; closing the backend
/// terminates the child and reclaims all its memory. This is the default backend
/// for `LLMService.withConnection`.
final class RemoteBackend: ServiceBackend, @unchecked Sendable {
    // MARK: - Configuration

    private let serviceBinaryURL: URL
    private let modelURL: URL
    private let config: EngineConfig
    private let verbose: Bool
    private let fake: Bool

    // MARK: - Transport state (guarded by lock)

    private let lock = NSLock()

    /// The running child process.
    private var process: Process?

    /// Pipe: client -> service (requests).
    private var requestPipe: Pipe?

    /// Handle for reading service events (the child's stdout).
    private var responseReadHandle: FileHandle?

    /// Whether shutdown() has been called.
    private var didShutdown = false

    /// Whether we expect the process to exit (shutdown in progress).
    private var expectedExit = false

    /// The PID-based kill handle for the deinit backstop.
    let transportHandle = TransportHandle()

    // MARK: - Reader task and in-flight request routing

    /// The background reader task that decodes events from the child.
    private var readerTask: Task<Void, Never>?

    /// Continuation for the initial ready/loadError handshake.
    private var readyContinuation: CheckedContinuation<Void, any Error>?

    /// Continuation for a buffered (non-streaming) in-flight request.
    private var inflightContinuation: CheckedContinuation<GenerationResult, any Error>?

    /// Stream continuation for a streaming in-flight request.
    private var inflightStreamContinuation: AsyncThrowingStream<StreamEvent, Error>.Continuation?

    /// The request id currently in-flight (for matching events).
    private var inflightID: UInt64?

    static let logger = Logger(
        subsystem: "net.scosman.biscotti", category: "RemoteBackend"
    )

    // MARK: - Init

    init(
        serviceBinary: URL,
        model: URL,
        config: EngineConfig,
        verbose: Bool = false,
        fake: Bool = false
    ) {
        serviceBinaryURL = serviceBinary
        modelURL = model
        self.config = config
        self.verbose = verbose
        self.fake = fake
    }

    // MARK: - ServiceBackend: start

    func start() async throws {
        // Ignore SIGPIPE so that writing to a broken pipe (e.g. after the child
        // crashes) raises EPIPE instead of killing the host process.
        signal(SIGPIPE, SIG_IGN)

        let process = Process()
        let reqPipe = Pipe()
        let respPipe = Pipe()

        // Build arguments
        var args = ["--model", modelURL.path]
        if let configData = try? JSONEncoder().encode(config),
           let configString = String(data: configData, encoding: .utf8)
        {
            args += ["--config", configString]
        }
        if fake {
            args.append("--fake")
        }

        process.executableURL = serviceBinaryURL
        process.arguments = args
        process.standardInput = reqPipe
        process.standardOutput = respPipe

        // Stderr: verbose -> inherited, else /dev/null
        if !verbose {
            process.standardError = FileHandle.nullDevice
        }

        do {
            try process.run()
        } catch {
            throw LLMServiceError.serviceUnavailable(
                "Failed to spawn service: \(error.localizedDescription)"
            )
        }

        lock.withLock {
            self.process = process
            requestPipe = reqPipe
            responseReadHandle = respPipe.fileHandleForReading
            transportHandle.pid = process.processIdentifier
            transportHandle.isRunning = true
        }

        // Wait for .ready or .loadError. The continuation is set up BEFORE the
        // reader task starts so the reader can't deliver .ready to a nil continuation.
        let readHandle = respPipe.fileHandleForReading
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            self.lock.withLock {
                self.readyContinuation = cont
            }
            // Start the reader task AFTER the continuation is installed
            self.readerTask = Task.detached { [weak self] in
                await self?.readerLoop(handle: readHandle)
            }
        }
    }

    // MARK: - ServiceBackend: generate

    func generate(
        id: UInt64, prompt: String, system: String?,
        options: GenerationOptions
    ) async throws -> GenerationResult {
        let request = ServiceRequest.generate(
            id: id, prompt: prompt, system: system,
            options: options, streaming: false
        )

        // Set up the continuation BEFORE writing so the reader can route the
        // response even if the service replies before we reach the await.
        return try await withCheckedThrowingContinuation { cont in
            lock.withLock {
                inflightID = id
                inflightContinuation = cont
            }
            do {
                try writeRequest(request)
            } catch {
                // Clean up and fail if the write itself fails. Only resume
                // if the continuation is still ours (reader hasn't taken it).
                let ourCont: CheckedContinuation<GenerationResult, any Error>? = lock.withLock {
                    let c = inflightContinuation
                    inflightContinuation = nil
                    inflightID = nil
                    return c
                }
                ourCont?.resume(throwing: error)
            }
        }
    }

    // MARK: - ServiceBackend: generateStreaming

    func generateStreaming(
        id: UInt64, prompt: String, system: String?,
        options: GenerationOptions
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        let request = ServiceRequest.generate(
            id: id, prompt: prompt, system: system,
            options: options, streaming: true
        )

        return AsyncThrowingStream { continuation in
            self.lock.withLock {
                self.inflightID = id
                self.inflightStreamContinuation = continuation
            }

            // When the consumer cancels (or the stream finishes for any reason),
            // send .cancel to the child so it stops any long-running work (e.g.
            // the __SLEEP__ fake prompt) and frees the serial worker. Without this,
            // a cancelled stream leaves the child blocked and the connection's
            // serial gate permanently held.
            continuation.onTermination = { @Sendable [weak self] _ in
                guard let self else { return }
                // Only cancel if this id is still the inflight one
                let shouldCancel = self.lock.withLock {
                    guard self.inflightID == id else { return false }
                    self.inflightStreamContinuation = nil
                    self.inflightID = nil
                    return true
                }
                if shouldCancel {
                    // Best-effort: ignore write errors on a dying pipe
                    try? self.writeRequest(.cancel(id: id))
                }
            }

            do {
                try self.writeRequest(request)
            } catch {
                continuation.finish(throwing: error)
                self.lock.withLock {
                    self.inflightID = nil
                    self.inflightStreamContinuation = nil
                }
            }
        }
    }

    // MARK: - ServiceBackend: cancel

    func cancel(id: UInt64) async {
        let request = ServiceRequest.cancel(id: id)
        try? writeRequest(request)
    }

    // MARK: - ServiceBackend: shutdown

    func shutdown() async {
        let alreadyShutdown = lock.withLock {
            if didShutdown { return true }
            didShutdown = true
            expectedExit = true
            return false
        }
        guard !alreadyShutdown else { return }

        // 1. Send .shutdown frame (best-effort)
        try? writeRequest(.shutdown)

        // 2. Close the request pipe (stdin EOF for the child)
        lock.withLock {
            try? requestPipe?.fileHandleForWriting.close()
            requestPipe = nil
        }

        // 3. Wait for process exit with grace timeout
        let proc = lock.withLock { process }
        if let proc, proc.isRunning {
            // Give the process 2 seconds to exit gracefully
            let exitTask = Task {
                proc.waitUntilExit()
            }

            let didExit = await Task {
                // Wait up to 2 seconds
                for _ in 0 ..< 20 {
                    if !proc.isRunning { return true }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                return !proc.isRunning
            }.value

            if !didExit {
                // 4. SIGTERM
                proc.terminate()

                // Wait another 500ms
                for _ in 0 ..< 5 {
                    if !proc.isRunning { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }

                if proc.isRunning {
                    // 5. SIGKILL
                    kill(proc.processIdentifier, SIGKILL)
                }
            }

            _ = await exitTask.result
        }

        // Clean up reader task
        readerTask?.cancel()

        // Mark transport as no longer running
        transportHandle.markStopped()

        // Fail any remaining in-flight requests
        failInflight(LLMServiceError.connectionClosed)
    }

    // MARK: - ServiceBackend: forceKill (deinit backstop)

    nonisolated func forceKill() {
        transportHandle.forceKillIfRunning()
    }

    // MARK: - Reader loop

    private func readerLoop(handle: FileHandle) async {
        while !Task.isCancelled {
            let event: ServiceEvent
            do {
                event = try FrameCodec.decode(ServiceEvent.self, from: handle)
            } catch {
                // EOF or decode error
                let isExpected = lock.withLock { expectedExit }
                if !isExpected {
                    Self.logger.error("Service reader: unexpected EOF/error: \(error)")
                    // Resolve ready continuation if pending
                    let readyCont = lock.withLock {
                        let c = readyContinuation
                        readyContinuation = nil
                        return c
                    }
                    readyCont?.resume(throwing: LLMServiceError.serviceInterrupted)

                    // Fail in-flight request
                    failInflight(LLMServiceError.serviceInterrupted)
                }
                transportHandle.markStopped()
                return
            }

            routeEvent(event)
        }
    }

    private func routeEvent(_ event: ServiceEvent) {
        switch event {
        case .ready:
            let cont = lock.withLock {
                let c = readyContinuation
                readyContinuation = nil
                return c
            }
            cont?.resume()

        case let .loadError(wireError):
            let error = wireError.toClientError()
            let cont = lock.withLock {
                let c = readyContinuation
                readyContinuation = nil
                return c
            }
            if let llmError = error as? LocalLLMError {
                cont?.resume(throwing: LLMServiceError.loadFailed(llmError))
            } else {
                cont?.resume(throwing: error)
            }

        case let .token(id, piece):
            lock.withLock {
                guard inflightID == id else { return }
                inflightStreamContinuation?.yield(.token(piece))
            }

        case let .reasoningToken(id, piece):
            lock.withLock {
                guard inflightID == id else { return }
                inflightStreamContinuation?.yield(.reasoningToken(piece))
            }

        case let .done(id, result):
            let (bufferedCont, streamCont) = lock.withLock {
                guard inflightID == id else { return (nil as CheckedContinuation<GenerationResult, any Error>?, nil as AsyncThrowingStream<StreamEvent, Error>.Continuation?) }
                let bc = inflightContinuation
                let sc = inflightStreamContinuation
                inflightContinuation = nil
                inflightStreamContinuation = nil
                inflightID = nil
                return (bc, sc)
            }

            if let bufferedCont {
                bufferedCont.resume(returning: result)
            } else if let streamCont {
                streamCont.yield(.done(result))
                streamCont.finish()
            }

        case let .requestError(id, wireError):
            let (bufferedCont, streamCont) = lock.withLock {
                guard inflightID == id else { return (nil as CheckedContinuation<GenerationResult, any Error>?, nil as AsyncThrowingStream<StreamEvent, Error>.Continuation?) }
                let bc = inflightContinuation
                let sc = inflightStreamContinuation
                inflightContinuation = nil
                inflightStreamContinuation = nil
                inflightID = nil
                return (bc, sc)
            }

            let error = wireError.toClientError()
            bufferedCont?.resume(throwing: error)
            streamCont?.finish(throwing: error)

        case let .fatal(wireError):
            Self.logger.error("Service fatal: \(String(describing: wireError))")
            let error = wireError.toClientError()

            // Resolve ready continuation if pending
            let readyCont = lock.withLock {
                let c = readyContinuation
                readyContinuation = nil
                return c
            }
            readyCont?.resume(throwing: LLMServiceError.serviceInterrupted)

            // Fail in-flight
            failInflight(error)
        }
    }

    // MARK: - Write (lock-guarded)

    private func writeRequest(_ request: ServiceRequest) throws {
        let frame = try FrameCodec.encode(request)
        lock.withLock {
            guard let fd = requestPipe?.fileHandleForWriting.fileDescriptor else { return }
            // Use POSIX write instead of FileHandle.write to avoid
            // NSFileHandleOperationException (ObjC exception, uncatchable by
            // Swift try/catch) on a broken pipe. With SIGPIPE ignored, POSIX
            // write returns -1/EPIPE instead, which we silently ignore.
            frame.withUnsafeBytes { buf in
                guard let ptr = buf.baseAddress else { return }
                var offset = 0
                while offset < frame.count {
                    let n = Darwin.write(fd, ptr + offset, frame.count - offset)
                    if n <= 0 { break } // EPIPE or error
                    offset += n
                }
            }
        }
    }

    // MARK: - In-flight failure

    private func failInflight(_ error: any Error) {
        let (bufferedCont, streamCont) = lock.withLock {
            let bc = inflightContinuation
            let sc = inflightStreamContinuation
            inflightContinuation = nil
            inflightStreamContinuation = nil
            inflightID = nil
            return (bc, sc)
        }
        bufferedCont?.resume(throwing: error)
        streamCont?.finish(throwing: error)
    }

    // MARK: - Binary resolution

    /// Resolve the `localllm-service` binary path.
    ///
    /// Resolution order:
    /// 1. Explicit `serviceBinary:` URL (if provided and exists).
    /// 2. `LOCALLLM_SERVICE_PATH` environment variable.
    /// 3. Walk up from the running process to find a sibling `localllm-service`.
    ///    Handles CLI (sibling of executable), xctest (sibling of `.xctest` bundle),
    ///    and Swift Testing (nested inside `.xctest/Contents/MacOS/`).
    static func resolveServiceBinary(explicit: URL? = nil) -> URL? {
        let fm = FileManager.default

        // 1. Explicit
        if let explicit, fm.fileExists(atPath: explicit.path) {
            return explicit
        }

        // 2. Environment variable
        if let envPath = ProcessInfo.processInfo.environment["LOCALLLM_SERVICE_PATH"],
           fm.fileExists(atPath: envPath)
        {
            return URL(fileURLWithPath: envPath)
        }

        let binaryName = "localllm-service"

        // 3. Walk up from the running process looking for the binary.
        //    Gather candidate starting directories from Bundle.main + argv[0].
        var startDirs: [URL] = []

        if let execDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            startDirs.append(execDir)
        }

        // Bundle URL covers the xctest case (.build/<triple>/debug/<X>.xctest)
        startDirs.append(Bundle.main.bundleURL.deletingLastPathComponent())

        // argv[0] is sometimes more reliable than Bundle (e.g. SPM test runner)
        let argv0 = URL(fileURLWithPath: CommandLine.arguments[0])
        startDirs.append(argv0.deletingLastPathComponent())

        for startDir in startDirs {
            var dir = startDir
            for _ in 0 ..< 6 {
                let candidate = dir.appendingPathComponent(binaryName)
                if fm.fileExists(atPath: candidate.path) {
                    return candidate
                }
                let parent = dir.deletingLastPathComponent()
                if parent.path == dir.path { break }
                dir = parent
            }
        }

        return nil
    }
}

// MARK: - TransportHandle (deinit backstop)

/// A `Sendable`, lock-guarded handle to the child process PID for the deinit backstop.
///
/// `forceKillIfRunning()` is `nonisolated` and safe to call from `deinit`.
final class TransportHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var _pid: pid_t = 0
    private var _isRunning = false

    var pid: pid_t {
        get { lock.withLock { _pid } }
        set { lock.withLock { _pid = newValue } }
    }

    var isRunning: Bool {
        get { lock.withLock { _isRunning } }
        set { lock.withLock { _isRunning = newValue } }
    }

    /// Get the PID if the transport is (believed to be) running.
    var runningPID: pid_t? {
        lock.withLock { _isRunning ? _pid : nil }
    }

    func markStopped() {
        lock.withLock { _isRunning = false }
    }

    func forceKillIfRunning() {
        let pidToKill: pid_t? = lock.withLock {
            guard _isRunning, _pid > 0 else { return nil }
            _isRunning = false
            return _pid
        }
        if let pid = pidToKill {
            RemoteBackend.logger.warning(
                "forceKill backstop: killing orphaned service process \(pid)"
            )
            kill(pid, SIGKILL)
        }
    }
}
