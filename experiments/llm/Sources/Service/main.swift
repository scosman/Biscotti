import Foundation
import LocalLLM

// localllm-service: child process for out-of-process LLM hosting.
//
// Speaks the framed-JSON wire protocol over stdin (requests) / stdout (events).
// Spawned by RemoteBackend; never invoked directly by users.
//
// Usage: localllm-service --model <path> [--config <json>] [--fake]

// MARK: - Argv parsing (minimal, no ArgumentParser dependency)

var modelPath: String?
var configJSON: String?
var fake = false

var i = 1
while i < CommandLine.arguments.count {
    let arg = CommandLine.arguments[i]
    switch arg {
    case "--model":
        i += 1
        guard i < CommandLine.arguments.count else {
            fputs("error: --model requires a value\n", stderr)
            _exit(1)
        }
        modelPath = CommandLine.arguments[i]
    case "--config":
        i += 1
        guard i < CommandLine.arguments.count else {
            fputs("error: --config requires a value\n", stderr)
            _exit(1)
        }
        configJSON = CommandLine.arguments[i]
    case "--fake":
        fake = true
    default:
        fputs("warning: unknown argument '\(arg)'\n", stderr)
    }
    i += 1
}

// Parse config from JSON if provided
var config = EngineConfig.default
if let json = configJSON, let data = json.data(using: .utf8) {
    do {
        config = try JSONDecoder().decode(EngineConfig.self, from: data)
    } catch {
        fputs("error: invalid --config JSON: \(error.localizedDescription)\n", stderr)
        _exit(1)
    }
}

// Validate: --model is required unless --fake
if !fake, modelPath == nil {
    fputs("error: --model is required (or use --fake for testing)\n", stderr)
    _exit(1)
}

let modelURL = modelPath.map { URL(fileURLWithPath: $0) }

// Run the service loop (blocks until shutdown/EOF)
let loop = ServiceLoop(
    modelURL: modelURL,
    config: config,
    fake: fake
)

// ServiceLoop.run() is async; bridge from synchronous main.
// Must use Task.detached: in Swift 6, main.swift top-level code is
// @MainActor-isolated, so `Task { ... }` would schedule on the main actor
// — but semaphore.wait() blocks the main thread, creating a deadlock.
// Task.detached runs on the cooperative pool, avoiding the deadlock.
let semaphore = DispatchSemaphore(value: 0)
Task.detached {
    await loop.run()
    semaphore.signal()
}
semaphore.wait()
