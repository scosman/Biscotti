import AppKit
import AudioCapture
import Foundation
import LocalLLM
import ManualTestKit
import os
import Transcription

/// Derives runnable versions of the ManualTestKit canonical scripts by mapping
/// over their steps and replacing only the placeholder closures with real
/// AudioRecorder and Transcriber calls.
///
/// All heavyweight objects (AudioRecorder, Transcriber) are created once and
/// shared across steps via captured references.
enum WiredScripts {
    /// Returns wired copies of all canonical scripts, ready for the runner.
    static func all() -> [TestScript] {
        allScripts.map { script in
            switch script.id {
            case "audio_capture":
                wireAudioCapture(script)
            case "transcription":
                wireTranscription(script)
            case "local_llm":
                wireLocalLLM(script)
            default:
                script
            }
        }
    }

    // MARK: - Shared state

    /// The recorder for the current recording run. `AudioRecorder` is
    /// single-use (reuse throws `recorderConsumed`), so a fresh one is
    /// created on `ac_start_recording` and discarded on `ac_stop_recording`.
    /// The lock just guards hand-off between the start and stop steps.
    private static let activeRecorder = OSAllocatedUnfairLock<AudioRecorder?>(
        initialState: nil
    )

    /// Shared transcriber instance (actor -- hosted via BiscottiTranscriber.xpc).
    private static let transcriber = Transcriber(
        backend: .hosted(serviceName: "net.scosman.biscotti.BiscottiTranscriber")
    )

    /// Directory for captured audio files.
    private static var captureDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("ManualTestApp/Captures", isDirectory: true)
    }

    // MARK: - Audio Capture wiring

    /// Maps over the canonical audio-capture script, replacing action/autoCheck closures.
    private static func wireAudioCapture(_ script: TestScript) -> TestScript {
        let paths = CapturePaths(
            micAAC: captureDirectory.appendingPathComponent("mic.aac"),
            systemAAC: captureDirectory.appendingPathComponent("system.aac")
        )

        let wiredSteps = script.steps.map { step -> TestStep in
            switch step {
            case let .action(id, label, _):
                switch id {
                case "ac_request_permissions":
                    return .action(id: id, label: label) { _ in
                        try FileManager.default.createDirectory(
                            at: captureDirectory,
                            withIntermediateDirectories: true
                        )
                        // Only request permissions — do NOT start the recording
                        // engine. This triggers the mic + system-audio TCC prompts
                        // without touching the mic AVAudioEngine/encoder. TCC grants
                        // are process/bundle-global, so a throwaway recorder is fine.
                        let probe = captureDirectory.appendingPathComponent("permission_probe.aac")
                        await AudioRecorder.live().requestPermissions(systemProbePath: probe)
                    }
                case "ac_start_recording":
                    return .action(id: id, label: label) { _ in
                        try FileManager.default.createDirectory(
                            at: captureDirectory,
                            withIntermediateDirectories: true
                        )
                        // Single-use: a fresh recorder per run, handed to the stop step.
                        let recorder = AudioRecorder.live()
                        activeRecorder.withLock { $0 = recorder }
                        do {
                            try await recorder.start(paths: paths)
                        } catch {
                            activeRecorder.withLock { $0 = nil }
                            throw error
                        }
                    }
                case "ac_stop_recording":
                    return .action(id: id, label: label) { _ in
                        let recorder = activeRecorder.withLock { current -> AudioRecorder? in
                            defer { current = nil }
                            return current
                        }
                        await recorder?.stop()
                        // Reveal both recordings in Finder so the human can play
                        // them for the playback questions that follow — there is
                        // otherwise no UI to open the captures folder.
                        await MainActor.run {
                            NSWorkspace.shared.activateFileViewerSelecting(
                                [paths.micAAC, paths.systemAAC]
                            )
                        }
                    }
                default:
                    return step
                }

            case let .autoCheck(id, label, _):
                switch id {
                case "ac_files_exist":
                    return .autoCheck(id: id, label: label) {
                        AutoChecks.checkAACFilesExist(
                            micURL: paths.micAAC,
                            systemURL: paths.systemAAC
                        )
                    }
                default:
                    return step
                }

            case .instruction, .humanQuestion:
                return step
            }
        }

        return TestScript(id: script.id, title: script.title, steps: wiredSteps)
    }

    // MARK: - Local LLM wiring

    /// The XPC service name for BiscottiLLM, matching the embedded xpc-service
    /// bundle identifier in project.yml.
    private static let llmServiceName = "net.scosman.biscotti.BiscottiLLM"

    /// Guard that the model file exists before attempting XPC inference.
    /// Throws a clear error directing the user to run the download step first,
    /// mirroring the CLI's `RunCommand.run()` guard.
    private static func requireModelDownloaded(_ model: URL) throws {
        guard FileManager.default.fileExists(atPath: model.path) else {
            throw ModelNotDownloadedError(path: model.path)
        }
    }

    /// Surfaced when an inference step is run before the model has been downloaded.
    private struct ModelNotDownloadedError: LocalizedError {
        let path: String
        var errorDescription: String? {
            "Model not found at \(path). Run the 'Download LLM model' step first."
        }
    }

    /// Maps over the canonical Local LLM script, replacing action/autoCheck closures
    /// with real LocalLLM calls. Inference steps use the XPC backend (BiscottiLLM.xpc);
    /// model download is in-process (ModelDownloader).
    ///
    /// Each inference step intentionally opens and closes its own connection. The
    /// per-request model load + memory reclamation cycle is part of what the manual
    /// test validates (XPC service spawn, load, generate, exit), so the per-step
    /// model-load latency is by design.
    private static func wireLocalLLM(_ script: TestScript) -> TestScript {
        let cache = LocalLLMPaths.defaultModelCacheDir

        let wiredSteps = script.steps.map { step -> TestStep in
            switch step {
            case let .action(id, label, _):
                switch id {
                case "llm_model_download":
                    return .action(id: id, label: label) { status in
                        let downloader = ModelDownloader(cacheDirectory: cache)
                        _ = try await downloader.download { bytes, total in
                            if let total {
                                let mb = Double(bytes) / 1_000_000
                                let totalMB = Double(total) / 1_000_000
                                let pct = Double(bytes) / Double(total) * 100
                                status(String(
                                    format: "Downloading: %.0f / %.0f MB (%.0f%%)",
                                    mb, totalMB, pct
                                ))
                            } else {
                                let mb = Double(bytes) / 1_000_000
                                status(String(format: "Downloading: %.0f MB", mb))
                            }
                        }
                        status("Download complete")
                    }

                case "llm_chat_system":
                    return .action(id: id, label: label) { status in
                        let model = ModelDownloader(cacheDirectory: cache).modelPath
                        try requireModelDownloaded(model)
                        status("Connecting to BiscottiLLM.xpc...")
                        let text = try await LLMService.withConnection(
                            model: model,
                            backend: .hosted(serviceName: llmServiceName)
                        ) { conn in
                            status("Connected. Generating with system + user messages...")
                            let result = try await conn.generate(
                                messages: [
                                    .system(
                                        "You are a helpful pirate assistant. "
                                            + "Always respond in pirate-speak."
                                    ),
                                    .user(
                                        "What is the capital of France? "
                                            + "Answer in one sentence."
                                    )
                                ],
                                options: GenerationOptions(maxTokens: 128)
                            )
                            return result.text
                        }
                        status("Response: \(text)")
                    }

                case "llm_xpc_inference":
                    return .action(id: id, label: label) { status in
                        let model = ModelDownloader(cacheDirectory: cache).modelPath
                        try requireModelDownloaded(model)
                        status("Connecting to BiscottiLLM.xpc...")
                        let text = try await LLMService.withConnection(
                            model: model,
                            backend: .hosted(serviceName: llmServiceName)
                        ) { conn in
                            status("Connected. Generating response...")
                            let result = try await conn.generate(
                                messages: [.user(
                                    "What is the capital of France? "
                                        + "Answer in one sentence."
                                )],
                                options: GenerationOptions(maxTokens: 128)
                            )
                            return result.text
                        }
                        status("Response: \(text)")
                    }

                case "llm_summarize_run":
                    return .action(id: id, label: label) { status in
                        let model = ModelDownloader(cacheDirectory: cache).modelPath
                        try requireModelDownloaded(model)
                        status("Connecting to BiscottiLLM.xpc...")
                        let text = try await LLMService.withConnection(
                            model: model,
                            backend: .hosted(serviceName: llmServiceName)
                        ) { conn in
                            status("Connected. Summarizing transcript...")
                            let result = try await conn.generate(
                                messages: [.user(
                                    "Summarize the following meeting transcript "
                                        + "in a few sentences:\n\n"
                                        + TestScript.sampleMeetingTranscript
                                )],
                                options: GenerationOptions(maxTokens: 512)
                            )
                            return result.text
                        }
                        status("Summary:\n\(text)")
                    }

                case "llm_action_items_run":
                    return .action(id: id, label: label) { status in
                        let model = ModelDownloader(cacheDirectory: cache).modelPath
                        try requireModelDownloaded(model)
                        status("Connecting to BiscottiLLM.xpc...")
                        let text = try await LLMService.withConnection(
                            model: model,
                            backend: .hosted(serviceName: llmServiceName)
                        ) { conn in
                            status("Connected. Extracting action items...")
                            let result = try await conn.generate(
                                messages: [.user(
                                    "Extract all action items from the following "
                                        + "meeting transcript. For each item list the owner "
                                        + "and deadline:\n\n"
                                        + TestScript.sampleMeetingTranscript
                                )],
                                options: GenerationOptions(maxTokens: 512)
                            )
                            return result.text
                        }
                        status("Action Items:\n\(text)")
                    }

                case "llm_speaker_names_run":
                    return .action(id: id, label: label) { status in
                        let model = ModelDownloader(cacheDirectory: cache).modelPath
                        try requireModelDownloaded(model)
                        status("Connecting to BiscottiLLM.xpc...")
                        let text = try await LLMService.withConnection(
                            model: model,
                            backend: .hosted(serviceName: llmServiceName)
                        ) { conn in
                            status("Connected. Identifying speakers...")
                            let result = try await conn.generate(
                                messages: [.user(
                                    "Identify all speakers in the following meeting "
                                        + "transcript. For each speaker, describe their "
                                        + "responsibilities and include a supporting quote:\n\n"
                                        + TestScript.sampleMeetingTranscript
                                )],
                                options: GenerationOptions(maxTokens: 512)
                            )
                            return result.text
                        }
                        status("Speakers:\n\(text)")
                    }

                case "llm_thinking_run":
                    return .action(id: id, label: label) { status in
                        let model = ModelDownloader(cacheDirectory: cache).modelPath
                        try requireModelDownloaded(model)
                        status("Connecting to BiscottiLLM.xpc...")
                        let output = try await LLMService.withConnection(
                            model: model,
                            backend: .hosted(serviceName: llmServiceName)
                        ) { conn in
                            status("Connected. Running thinking-mode inference...")
                            return try await conn.generate(
                                messages: [.user(
                                    "Analyze the following meeting transcript. "
                                        + "Think step by step about who has the most "
                                        + "work and whether all deadlines are realistic, "
                                        + "then give a final assessment:\n\n"
                                        + TestScript.sampleMeetingTranscript
                                )],
                                options: GenerationOptions(
                                    maxTokens: 1024,
                                    thinking: .auto
                                )
                            )
                        }
                        var display = ""
                        if let reasoning = output.reasoning, !reasoning.isEmpty {
                            display += "Thinking:\n\(reasoning)\n\n"
                        }
                        display += "Response:\n\(output.text)"
                        status(display)
                    }

                case "llm_kv_reuse":
                    return .action(id: id, label: label) { status in
                        let model = ModelDownloader(cacheDirectory: cache).modelPath
                        try requireModelDownloaded(model)
                        status("Connecting to BiscottiLLM.xpc...")
                        try await LLMService.withConnection(
                            model: model,
                            backend: .hosted(serviceName: llmServiceName)
                        ) { conn in
                            let options = GenerationOptions(maxTokens: 128, temperature: 0)

                            // Turn 1: system + user with the sample transcript
                            let systemMsg = LLMMessage.system(
                                "You are a meeting analyst. Answer precisely."
                            )
                            let userMsg = LLMMessage.user(
                                "Summarize this meeting transcript in one sentence:\n\n"
                                    + TestScript.sampleMeetingTranscript
                            )

                            status("Turn 1: Generating with fresh cache...")
                            let result1 = try await conn.generate(
                                messages: [systemMsg, userMsg],
                                options: options
                            )
                            let prefillMs1 = String(
                                format: "%.0f", result1.promptEvalDuration * 1000
                            )
                            status(
                                "Turn 1 done.\n"
                                    + "  cached=\(result1.cachedPromptTokenCount) "
                                    + "prompt=\(result1.promptTokenCount) tokens\n"
                                    + "  prefill=\(prefillMs1)ms\n"
                                    + "  response: \(result1.text.prefix(200))\n\n"
                                    + "Turn 2: Extending conversation (should reuse prefix)..."
                            )

                            // Turn 2: extend with the model's response + follow-up
                            let result2 = try await conn.generate(
                                messages: [
                                    systemMsg,
                                    userMsg,
                                    .assistant(result1.text),
                                    .user("List the action items from the transcript.")
                                ],
                                options: options
                            )
                            let prefillMs2 = String(
                                format: "%.0f", result2.promptEvalDuration * 1000
                            )
                            status(
                                "Turn 1:\n"
                                    + "  cached=\(result1.cachedPromptTokenCount) "
                                    + "prompt=\(result1.promptTokenCount) "
                                    + "prefill=\(prefillMs1)ms\n"
                                    + "  \(result1.text.prefix(200))\n\n"
                                    + "Turn 2:\n"
                                    + "  cached=\(result2.cachedPromptTokenCount) "
                                    + "prompt=\(result2.promptTokenCount) "
                                    + "prefill=\(prefillMs2)ms\n"
                                    + "  \(result2.text.prefix(200))"
                            )
                        }
                    }

                case "llm_streaming_run":
                    return .action(id: id, label: label) { status in
                        let model = ModelDownloader(cacheDirectory: cache).modelPath
                        try requireModelDownloaded(model)
                        status("Connecting to BiscottiLLM.xpc...")
                        try await LLMService.withConnection(
                            model: model,
                            backend: .hosted(serviceName: llmServiceName)
                        ) { conn in
                            status("Connected. Streaming tokens...")
                            var thinking = ""
                            var response = ""

                            func render() -> String {
                                var display = ""
                                if !thinking.isEmpty {
                                    display += "[Thinking]\n\(thinking)\n\n"
                                }
                                if !response.isEmpty {
                                    display += "[Response]\n\(response)"
                                }
                                return display
                            }

                            let stream = await conn.generateStreaming(
                                messages: [.user(
                                    "Think about what makes a good meeting, "
                                        + "then list three tips for effective meetings."
                                )],
                                options: GenerationOptions(
                                    maxTokens: 512,
                                    thinking: .auto
                                )
                            )
                            for try await event in stream {
                                switch event {
                                case let .reasoningToken(piece):
                                    thinking += piece
                                    status(render())
                                case let .token(piece):
                                    response += piece
                                    status(render())
                                case .done:
                                    break
                                }
                            }
                            // Final display already set by the last token event.
                        }
                    }

                default:
                    return step
                }

            case let .autoCheck(id, label, _):
                switch id {
                case "llm_reclamation":
                    return .autoCheck(id: id, label: label) {
                        // Brief pause to let the service process exit after
                        // connection invalidation.
                        try? await Task.sleep(for: .seconds(2))
                        return AutoChecks.checkNoLLMServiceRunning()
                    }
                default:
                    return step
                }

            case .instruction, .humanQuestion:
                return step
            }
        }

        return TestScript(id: script.id, title: script.title, steps: wiredSteps)
    }

    // MARK: - Transcription wiring

    /// Maps over the canonical transcription script, replacing action closures
    /// for the model download/cache steps. The remaining steps (humanQuestions)
    /// need no wiring.
    private static func wireTranscription(_ script: TestScript) -> TestScript {
        let wiredSteps = script.steps.map { step -> TestStep in
            switch step {
            case let .action(id, label, _):
                switch id {
                case "tx_clear_cache":
                    return .action(id: id, label: label) { _ in
                        try await transcriber.clearCache()
                    }
                case "tx_model_download":
                    return .action(id: id, label: label) { status in
                        try await transcriber.ensureModelsDownloaded(status: status)
                    }
                default:
                    return step
                }

            case .instruction, .humanQuestion, .autoCheck:
                return step
            }
        }

        return TestScript(id: script.id, title: script.title, steps: wiredSteps)
    }
}
