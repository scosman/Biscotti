import Foundation

/// The service-side event loop for the out-of-process LLM backend.
///
/// Reads `ServiceRequest` frames from stdin, runs generation on a single serial
/// worker, and writes `ServiceEvent` frames to a private output fd. The stdout fd
/// is "rescued" (dup'd to a private descriptor) and fd 1 is redirected to /dev/null
/// so that any stray printf/fprintf(stdout) from llama.cpp/ggml/Metal cannot
/// corrupt the frame channel.
///
/// In `--fake` mode, no model is loaded: the loop emits canned tokens immediately.
/// Magic prompts `__CRASH__` and `__SLEEP__` exercise the crash and cancellation paths.
public final class ServiceLoop: Sendable {
    private let modelURL: URL?
    private let config: EngineConfig
    private let fake: Bool

    /// Optional overrides for testing (pipe-based instead of real stdin/stdout).
    /// When nil, the loop uses the real process file descriptors.
    private let inputOverride: FileHandle?
    private let outputOverride: FileHandle?

    // MARK: - Init

    /// Create a service loop.
    ///
    /// - Parameters:
    ///   - modelURL: Path to the GGUF model. Required unless `fake` is true.
    ///   - config: Engine configuration.
    ///   - fake: When true, emit canned tokens without loading a model.
    public init(
        modelURL: URL?,
        config: EngineConfig = .default,
        fake: Bool = false
    ) {
        self.modelURL = modelURL
        self.config = config
        self.fake = fake
        inputOverride = nil
        outputOverride = nil
    }

    /// Testing initializer: use explicit file handles instead of real stdin/stdout.
    init(
        modelURL: URL?,
        config: EngineConfig = .default,
        fake: Bool = false,
        inputHandle: FileHandle,
        outputHandle: FileHandle
    ) {
        self.modelURL = modelURL
        self.config = config
        self.fake = fake
        inputOverride = inputHandle
        outputOverride = outputHandle
    }

    // MARK: - Run

    /// Run the service loop until shutdown or stdin EOF, then `_exit(0)`.
    ///
    /// This method never returns normally in production -- it calls `_exit(0)` to
    /// avoid the ggml-metal rsets SIGABRT. In test mode (inputOverride != nil) it
    /// returns normally instead of exiting.
    public func run() async {
        // Step 0: Rescue-and-gag stdout.
        let frameOutput: FileHandle
        let isTestMode = inputOverride != nil

        if let override = outputOverride {
            frameOutput = override
        } else {
            let rescuedFD = dup(STDOUT_FILENO)
            guard rescuedFD >= 0 else {
                fputs("error: failed to dup stdout\n", stderr)
                _exit(1)
            }
            // Redirect fd 1 to /dev/null so backend noise can't hit the frame channel
            let devNull = open("/dev/null", O_WRONLY)
            if devNull >= 0 {
                dup2(devNull, STDOUT_FILENO)
                close(devNull)
            }
            // Prevent child processes from inheriting the frame fd
            _ = fcntl(rescuedFD, F_SETFD, FD_CLOEXEC)
            frameOutput = FileHandle(fileDescriptor: rescuedFD, closeOnDealloc: false)
        }

        let inputHandle = inputOverride ?? FileHandle.standardInput

        // Step 1: Load model (or fake) and send ready/loadError.
        let engine: (any InferenceEngine)?
        if fake {
            engine = nil
            writeEvent(.ready, to: frameOutput)
        } else {
            guard let url = modelURL else {
                writeEvent(.loadError(.service("No model path provided")), to: frameOutput)
                exitOrReturn(isTestMode)
                return
            }
            do {
                let realEngine = try await LLMEngine(modelPath: url, config: config)
                engine = realEngine
                writeEvent(.ready, to: frameOutput)
            } catch {
                writeEvent(.loadError(WireError.from(error)), to: frameOutput)
                exitOrReturn(isTestMode)
                return
            }
        }

        // Step 2: Reader + worker loop.
        // The worker is a single serial task; `.cancel` cancels it.
        let workerHandle = WorkerHandle()

        // Read requests until EOF or .shutdown
        while true {
            let request: ServiceRequest
            do {
                request = try FrameCodec.decode(ServiceRequest.self, from: inputHandle)
            } catch is FrameCodecError {
                // EOF or corrupt frame -- treat as parent died, exit cleanly
                break
            } catch {
                break
            }

            switch request {
            case let .generate(id, prompt, system, options, streaming):
                // Cancel any prior worker (shouldn't happen with serial client, but defensive)
                await workerHandle.cancelAndWait()

                let task = Task {
                    await self.handleGenerate(
                        id: id, prompt: prompt, system: system, options: options,
                        streaming: streaming, engine: engine, frameOutput: frameOutput
                    )
                }
                await workerHandle.set(task)

            case .cancel:
                await workerHandle.cancelAndWait()

            case .shutdown:
                await workerHandle.cancelAndWait()
                // Fall through to teardown
                break
            }

            // Check if we just handled .shutdown -- break the outer loop
            if case .shutdown = request { break }
        }

        // Step 3: Teardown
        await workerHandle.cancelAndWait()

        if let realEngine = engine {
            await realEngine.unload()
        }

        if !fake, engine != nil {
            LocalLLMRuntime.shutdown()
        }

        fflush(stderr)

        exitOrReturn(isTestMode)
    }

    // MARK: - Generation handler

    private func handleGenerate(
        id: UInt64, prompt: String, system: String?,
        options: GenerationOptions, streaming: Bool,
        engine: (any InferenceEngine)?, frameOutput: FileHandle
    ) async {
        if fake {
            await handleFakeGenerate(
                id: id, prompt: prompt, streaming: streaming,
                frameOutput: frameOutput
            )
            return
        }

        guard let engine else {
            writeEvent(.requestError(id: id, error: .service("No engine loaded")),
                       to: frameOutput)
            return
        }

        if streaming {
            let stream = await engine.generateStreaming(
                prompt: prompt, system: system, options: options
            )
            do {
                for try await event in stream {
                    if Task.isCancelled {
                        writeEvent(.requestError(id: id, error: .cancelled), to: frameOutput)
                        return
                    }
                    switch event {
                    case let .token(piece):
                        writeEvent(.token(id: id, piece: piece), to: frameOutput)
                    case let .reasoningToken(piece):
                        writeEvent(.reasoningToken(id: id, piece: piece), to: frameOutput)
                    case let .done(result):
                        writeEvent(.done(id: id, result: result), to: frameOutput)
                    }
                }
            } catch {
                if Task.isCancelled {
                    writeEvent(.requestError(id: id, error: .cancelled), to: frameOutput)
                } else {
                    writeEvent(.requestError(id: id, error: WireError.from(error)),
                               to: frameOutput)
                }
            }
        } else {
            do {
                let result = try await engine.generate(
                    prompt: prompt, system: system, options: options
                )
                writeEvent(.done(id: id, result: result), to: frameOutput)
            } catch {
                if Task.isCancelled {
                    writeEvent(.requestError(id: id, error: .cancelled), to: frameOutput)
                } else {
                    writeEvent(.requestError(id: id, error: WireError.from(error)),
                               to: frameOutput)
                }
            }
        }
    }

    // MARK: - Fake mode

    private func handleFakeGenerate(
        id: UInt64, prompt: String, streaming: Bool,
        frameOutput: FileHandle
    ) async {
        // Magic prompt: __CRASH__ -> simulate service crash
        if prompt.hasPrefix("__CRASH__") {
            _exit(1)
        }

        // Magic prompt: __SLEEP__ -> cancellable long sleep
        if prompt.hasPrefix("__SLEEP__") {
            do {
                // Sleep for a very long time; cancellation will interrupt this
                try await Task.sleep(for: .seconds(3600))
            } catch {
                // Cancelled -- send cancellation error
                writeEvent(.requestError(id: id, error: .cancelled), to: frameOutput)
                return
            }
        }

        let cannedTokens = ["Hello", " from", " fake", " service"]
        let cannedText = cannedTokens.joined()
        let cannedResult = GenerationResult(
            text: cannedText,
            reasoning: nil,
            promptTokenCount: 5,
            generatedTokenCount: Int(cannedTokens.count),
            finishReason: .endOfTurn,
            loadDuration: nil,
            promptEvalDuration: 0.001,
            generationDuration: 0.002,
            totalDuration: 0.003,
            renderedPrompt: prompt,
            rawText: cannedText,
            embeddedChatTemplate: nil
        )

        if streaming {
            for token in cannedTokens {
                if Task.isCancelled {
                    writeEvent(.requestError(id: id, error: .cancelled), to: frameOutput)
                    return
                }
                writeEvent(.token(id: id, piece: token), to: frameOutput)
            }
        }

        writeEvent(.done(id: id, result: cannedResult), to: frameOutput)
    }

    // MARK: - Frame writing

    private func writeEvent(_ event: ServiceEvent, to handle: FileHandle) {
        do {
            let frame = try FrameCodec.encode(event)
            handle.write(frame)
        } catch {
            fputs("ServiceLoop: failed to encode event: \(error)\n", stderr)
        }
    }

    // MARK: - Exit

    private func exitOrReturn(_ isTestMode: Bool) {
        if isTestMode {
            return
        }
        _exit(0)
    }
}

// MARK: - Worker handle (actor for safe task management)

private actor WorkerHandle {
    private var currentTask: Task<Void, Never>?

    func set(_ task: Task<Void, Never>) {
        currentTask = task
    }

    func cancelAndWait() async {
        guard let task = currentTask else { return }
        task.cancel()
        _ = await task.result
        currentTask = nil
    }
}
