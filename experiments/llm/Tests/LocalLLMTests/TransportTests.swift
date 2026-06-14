import Foundation
import Testing

@testable import LocalLLM

// MARK: - Binary resolution

/// Resolve the `localllm-service` binary path, or nil if not built.
private let serviceBinaryURL: URL? = {
    if let url = RemoteBackend.resolveServiceBinary() {
        return url
    }
    let thisFile = URL(fileURLWithPath: #filePath)
    let packageRoot = thisFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let binaryName = "localllm-service"
    let fm = FileManager.default
    let candidates = [
        packageRoot.appendingPathComponent(".build/arm64-apple-macosx/debug/\(binaryName)"),
        packageRoot.appendingPathComponent(".build/debug/\(binaryName)"),
        packageRoot.appendingPathComponent(".build/x86_64-apple-macosx/debug/\(binaryName)"),
    ]
    for candidate in candidates {
        if fm.fileExists(atPath: candidate.path) {
            return candidate
        }
    }
    return nil
}()

private let isServiceBinaryAvailable: Bool = serviceBinaryURL != nil

private func requireServiceBinary() throws -> URL {
    guard let url = serviceBinaryURL else {
        throw ServiceBinaryNotFound()
    }
    return url
}

private struct ServiceBinaryNotFound: Error, CustomStringConvertible {
    let description = "localllm-service binary not found -- run build_llm first"
}

// MARK: - Transport Lifecycle

@Suite("RemoteBackend Transport Lifecycle",
       .enabled(if: isServiceBinaryAvailable),
       .serialized,
       .timeLimit(.minutes(1)))
struct TransportLifecycleTests {
    @Test("Open fake service reaches ready state")
    func openReady() async throws {
        let binary = try requireServiceBinary()
        let (conn, pid) = try await LLMService.openFakeConnection(serviceBinary: binary)
        let state = await conn.state
        #expect(state == .ready)
        #expect(pid > 0)
        await conn.close()
    }

    @Test("Close reclaims child process (pid gone)")
    func closeReclaims() async throws {
        let binary = try requireServiceBinary()
        let (conn, pid) = try await LLMService.openFakeConnection(serviceBinary: binary)
        #expect(pid > 0)
        #expect(kill(pid, 0) == 0, "Process should be running before close")
        await conn.close()
        try await Task.sleep(for: .milliseconds(500))
        let result = kill(pid, 0)
        #expect(result == -1, "Expected kill to fail (process should be gone)")
        #expect(errno == ESRCH, "Expected ESRCH (no such process), got errno \(errno)")
    }

    @Test("Deinit backstop kills dropped connection")
    func deinitBackstop() async throws {
        let binary = try requireServiceBinary()
        var pid: pid_t = 0
        do {
            let (conn, p) = try await LLMService.openFakeConnection(serviceBinary: binary)
            pid = p
            #expect(pid > 0)
            #expect(kill(pid, 0) == 0, "Process should be running before drop")
            _ = conn
        }
        try await Task.sleep(for: .milliseconds(1000))
        let result = kill(pid, 0)
        #expect(result == -1, "Expected kill to fail (process should be gone)")
        #expect(errno == ESRCH, "Expected ESRCH after deinit backstop kill")
    }
}

// MARK: - Fake Service Generation

@Suite("RemoteBackend Fake Generation",
       .enabled(if: isServiceBinaryAvailable),
       .serialized,
       .timeLimit(.minutes(1)))
struct FakeGenerationTests {
    @Test("Buffered generate returns fake result")
    func fakeGenerate() async throws {
        let binary = try requireServiceBinary()
        let (conn, _) = try await LLMService.openFakeConnection(serviceBinary: binary)
        let result = try await conn.generate(prompt: "test prompt")
        #expect(result.text == "Hello from fake service")
        #expect(result.finishReason == .endOfTurn)
        #expect(result.generatedTokenCount == 4)
        await conn.close()
    }

    @Test("Streaming yields fake tokens then done")
    func fakeStream() async throws {
        let binary = try requireServiceBinary()
        let (conn, _) = try await LLMService.openFakeConnection(serviceBinary: binary)
        var tokens: [String] = []
        var doneResult: GenerationResult?
        let stream = await conn.generateStreaming(prompt: "test prompt")
        for try await event in stream {
            switch event {
            case let .token(piece):
                tokens.append(piece)
            case .reasoningToken:
                break
            case let .done(result):
                doneResult = result
            }
        }
        #expect(tokens == ["Hello", " from", " fake", " service"])
        #expect(doneResult?.text == "Hello from fake service")
        await conn.close()
    }

    @Test("Multiple sequential generates on one connection")
    func multipleGenerates() async throws {
        let binary = try requireServiceBinary()
        let (conn, _) = try await LLMService.openFakeConnection(serviceBinary: binary)
        let r1 = try await conn.generate(prompt: "first")
        let r2 = try await conn.generate(prompt: "second")
        #expect(r1.text == "Hello from fake service")
        #expect(r2.text == "Hello from fake service")
        await conn.close()
    }
}

// MARK: - Cancellation

@Suite("RemoteBackend Cancellation",
       .enabled(if: isServiceBinaryAvailable),
       .serialized,
       .timeLimit(.minutes(1)))
struct TransportCancellationTests {
    @Test("Cancel mid-stream frees queue for next request")
    func cancelMidStream() async throws {
        let binary = try requireServiceBinary()
        let (conn, _) = try await LLMService.openFakeConnection(serviceBinary: binary)

        // Start a long-running stream in a separate task
        let streamTask = Task {
            let stream = await conn.generateStreaming(prompt: "__SLEEP__ long running")
            for try await _ in stream {}
        }

        // Let the stream establish, then cancel
        try await Task.sleep(for: .milliseconds(500))
        streamTask.cancel()

        // Wait for the cancelled task to finish
        do {
            try await streamTask.value
        } catch {
            // Expected: cancellation error
        }

        // The serial gate should be released; a subsequent generate must succeed
        let result = try await conn.generate(prompt: "after cancel")
        #expect(result.text == "Hello from fake service")

        await conn.close()
    }
}

// MARK: - Crash Handling

@Suite("RemoteBackend Crash Handling",
       .enabled(if: isServiceBinaryAvailable),
       .serialized,
       .timeLimit(.minutes(1)))
struct CrashHandlingTests {
    @Test("Service crash produces serviceInterrupted and failed state")
    func crashServiceInterrupted() async throws {
        let binary = try requireServiceBinary()
        let (conn, _) = try await LLMService.openFakeConnection(serviceBinary: binary)

        do {
            _ = try await conn.generate(prompt: "__CRASH__ now")
            Issue.record("Expected serviceInterrupted error")
        } catch let error as LLMServiceError {
            #expect(error == .serviceInterrupted)
        }

        let state = await conn.state
        if case .failed = state {
            // Expected
        } else {
            Issue.record("Expected failed state, got \(state)")
        }

        await conn.close()
    }
}
