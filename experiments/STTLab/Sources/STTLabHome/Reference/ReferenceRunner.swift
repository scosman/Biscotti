import Foundation
import STTLabCore
import WhisperKit

// MARK: - Status file

/// Per-meeting reference status, saved in `reference/<mid>/status.json`.
public struct ReferenceStatus: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var meetingID: String
    public var status: RunStatus
    public var model: String
    public var zdr: Bool
    public var chunkCount: Int
    public var completedChunks: Int
    public var totalCost: Double?
    public var wordsPresent: Bool?
    public var error: ErrorInfo?

    public init(
        schemaVersion: Int = SchemaVersions.reference,
        meetingID: String,
        status: RunStatus,
        model: String,
        zdr: Bool,
        chunkCount: Int,
        completedChunks: Int,
        totalCost: Double? = nil,
        wordsPresent: Bool? = nil,
        error: ErrorInfo? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.meetingID = meetingID
        self.status = status
        self.model = model
        self.zdr = zdr
        self.chunkCount = chunkCount
        self.completedChunks = completedChunks
        self.totalCost = totalCost
        self.wordsPresent = wordsPresent
        self.error = error
    }
}

/// Metadata saved per chunk alongside the raw response.
public struct ChunkMeta: Codable, Sendable, Equatable {
    public var chunkIndex: Int
    public var startSample: Int
    public var endSample: Int
    public var startSeconds: Double
    public var endSeconds: Double
    public var requestMetadata: [String: String]
    public var httpStatus: Int
    public var responseHeaders: [String: String]
    public var attempts: Int
    public var latencySeconds: Double
    public var requestedAt: Date

    public init(
        chunkIndex: Int,
        startSample: Int,
        endSample: Int,
        startSeconds: Double,
        endSeconds: Double,
        requestMetadata: [String: String],
        httpStatus: Int,
        responseHeaders: [String: String],
        attempts: Int,
        latencySeconds: Double,
        requestedAt: Date
    ) {
        self.chunkIndex = chunkIndex
        self.startSample = startSample
        self.endSample = endSample
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.requestMetadata = requestMetadata
        self.httpStatus = httpStatus
        self.responseHeaders = responseHeaders
        self.attempts = attempts
        self.latencySeconds = latencySeconds
        self.requestedAt = requestedAt
    }
}

// MARK: - Configuration

/// Configuration for a reference run.
public struct ReferenceConfig: Sendable {
    public var model: String
    public var zdr: Bool
    public var chunkSeconds: Double
    public var pricePerHour: Double

    public init(
        model: String = "microsoft/mai-transcribe-2",
        zdr: Bool = true,
        chunkSeconds: Double = 300,
        pricePerHour: Double = 0.10
    ) {
        self.model = model
        self.zdr = zdr
        self.chunkSeconds = chunkSeconds
        self.pricePerHour = pricePerHour
    }
}

// MARK: - Errors

public enum ReferenceRunnerError: Error {
    case apiKeyMissing
    case modelMismatch(saved: String, requested: String)
    case fatalAPIError(status: Int, body: String, message: String)
    case consentDeclined
    case stdinNotTTY
}

// MARK: - Runner

/// Orchestrates the OpenRouter reference model run for all meetings in the bundle.
///
/// Per meeting: plans chunks from the merged WAV, sends each chunk through
/// `OpenRouterClient` with retry and split logic, and saves raw responses +
/// metadata + status files under `home/reference/<mid>/`.
public enum ReferenceRunner {
    // MARK: - Public entry points

    /// Run the reference model on all (or selected) meetings.
    @discardableResult
    public static func run(
        workspace: URL,
        meetingFilter: [String] = [],
        force: Bool = false,
        config: ReferenceConfig = ReferenceConfig(),
        skipConsent: Bool = false,
        log: RunLog
    ) async throws -> (completed: Int, failed: Int, skipped: Int) {
        let apiKey = try requireAPIKey()
        _ = try ConsentGate.require(workspace: workspace)
        let bundleDir = workspace.appendingPathComponent("bundle")
        let bundle = try BundleLoader.load(from: bundleDir)
        let refDir = workspace.appendingPathComponent("home/reference")

        let client = OpenRouterClient(apiKey: apiKey)

        let meetingsToProcess = filterMeetings(
            bundle.manifest.meetings, filter: meetingFilter
        )

        // Consent prompt (unless --yes).
        if !skipConsent {
            let totalHours = bundle.metas
                .filter { meetingsToProcess.contains($0.meetingID) }
                .reduce(0.0) { $0 + $1.durationSeconds } / 3600
            let estimatedCost = totalHours * config.pricePerHour
            log.log("Reference: \(meetingsToProcess.count) meetings, "
                + "\(String(format: "%.1f", totalHours)) hours, "
                + "est. $\(String(format: "%.2f", estimatedCost)) "
                + "(model: \(config.model), ZDR: \(config.zdr))")
            log.log("Proceed? [y/N]")

            guard isInteractiveTerminal() else {
                throw ReferenceRunnerError.stdinNotTTY
            }
            guard readConsentFromStdin() else {
                throw ReferenceRunnerError.consentDeclined
            }
        }

        var completed = 0
        var failed = 0
        var skipped = 0

        for mid in meetingsToProcess {
            let meetingRefDir = refDir.appendingPathComponent(mid)
            let statusURL = meetingRefDir.appendingPathComponent("status.json")

            // Skip if already completed (unless force).
            if !force, FileManager.default.fileExists(atPath: statusURL.path) {
                let existing: ReferenceStatus? = try? JSONFiles.read(from: statusURL)
                if existing?.status == .completed {
                    // Enforce one model per workspace.
                    if let savedModel = existing?.model, savedModel != config.model {
                        throw ReferenceRunnerError.modelMismatch(
                            saved: savedModel, requested: config.model
                        )
                    }
                    log.log("\(mid): reference already completed (skip)")
                    skipped += 1
                    continue
                }
            }

            log.log("\(mid): running reference (\(config.model))...")

            do {
                let meta = bundle.metas.first { $0.meetingID == mid }!
                let result = try await runMeeting(
                    mid: mid,
                    meta: meta,
                    bundleDir: bundleDir,
                    meetingRefDir: meetingRefDir,
                    client: client,
                    config: config,
                    force: force,
                    log: log
                )
                try JSONFiles.write(result, to: statusURL)

                if result.status == .completed {
                    completed += 1
                    let costStr = result.totalCost.map { String(format: "$%.4f", $0) } ?? "?"
                    log.log("\(mid): done (\(result.completedChunks) chunks, cost: \(costStr), "
                        + "words: \(result.wordsPresent == true ? "yes" : "no"))")
                } else {
                    failed += 1
                    log.log("\(mid): FAILED — \(result.error?.description ?? "unknown")")
                }
            } catch let error as ReferenceRunnerError {
                // Fatal errors (bad key, model mismatch) stop the whole run.
                throw error
            } catch {
                let status = ReferenceStatus(
                    meetingID: mid, status: .failed, model: config.model,
                    zdr: config.zdr, chunkCount: 0, completedChunks: 0,
                    error: ErrorInfo(error)
                )
                try? JSONFiles.write(status, to: statusURL)
                log.log("\(mid): FAILED — \(error)")
                failed += 1
            }
        }

        log.log("Reference: \(completed) completed, \(failed) failed, \(skipped) skipped")
        return (completed, failed, skipped)
    }

    /// Run probe mode: send 60 seconds of the first meeting and print diagnostics.
    public static func probe(
        workspace: URL,
        config: ReferenceConfig = ReferenceConfig(),
        log: RunLog
    ) async throws {
        let apiKey = try requireAPIKey()
        try ConsentGate.require(workspace: workspace)
        let bundleDir = workspace.appendingPathComponent("bundle")
        let bundle = try BundleLoader.load(from: bundleDir)
        let probeDir = workspace.appendingPathComponent("home/reference/probe")

        let client = OpenRouterClient(apiKey: apiKey)

        guard let firstMID = bundle.manifest.meetings.first else {
            log.log("No meetings in bundle")
            return
        }

        let meta = bundle.metas.first { $0.meetingID == firstMID }!
        let wavURL = bundleDir.appendingPathComponent("meetings/\(firstMID)/\(meta.audioFile)")
        let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: wavURL.path)

        // First 60 seconds.
        let probeSamples = min(samples.count, Int(60 * meta.sampleRate))
        let wavData = WAVFile.int16WAVData(samples: samples, range: 0 ..< probeSamples)

        let language = languageFromLocale(meta.appleLocale)
        let request = TranscriptionRequest(
            model: config.model,
            wavData: wavData,
            language: language,
            zdr: config.zdr
        )

        log.log("Probe: sending \(String(format: "%.0f", Double(probeSamples) / meta.sampleRate))s "
            + "of \(firstMID) to \(config.model)...")

        let outcome = await client.transcribe(request)

        switch outcome {
        case let .success(status, _, body):
            // Save raw response.
            try FileManager.default.createDirectory(at: probeDir, withIntermediateDirectories: true)
            try body.write(to: probeDir.appendingPathComponent("response.json"))
            try JSONFiles.write(request.metadata(), to: probeDir.appendingPathComponent("meta.json"))

            log.log("HTTP \(status)")
            if let parsed = try? JSONDecoder().decode(ReferenceResponse.self, from: body) {
                let wordCount = parsed.words?.count ?? 0
                let segCount = parsed.segments?.count ?? 0
                log.log("Words: \(wordCount), Segments: \(segCount)")
                if let words = parsed.words?.prefix(10) {
                    for w in words {
                        log.log("  \(String(format: "%.2f", w.start))-\(String(format: "%.2f", w.end)) \(w.word)")
                    }
                }
                if let usage = parsed.usage {
                    if let cost = usage.cost { log.log("Cost: $\(String(format: "%.4f", cost))") }
                    if let secs = usage.seconds { log.log("Audio seconds billed: \(secs)") }
                }
                if let model = parsed.model { log.log("Model: \(model)") }
                if let provider = parsed.provider { log.log("Provider: \(provider)") }
            } else {
                log.log("Could not parse response body")
            }

        case let .retryable(status, _, message):
            log.log("Retryable error: \(message) (status: \(status.map(String.init) ?? "nil"))")
        case let .timeoutLike(status, message):
            log.log("Timeout-like error: \(message) (status: \(status.map(String.init) ?? "nil"))")
        case let .fatal(status, body):
            let bodyStr = String(data: body.prefix(500), encoding: .utf8) ?? "<binary>"
            log.log("Fatal error: HTTP \(status) — \(bodyStr)")
        }
    }

    // MARK: - Per-meeting processing

    private static func runMeeting(
        mid: String,
        meta: MeetingMeta,
        bundleDir: URL,
        meetingRefDir: URL,
        client: OpenRouterClient,
        config: ReferenceConfig,
        force: Bool,
        log: RunLog
    ) async throws -> ReferenceStatus {
        let fm = FileManager.default
        try fm.createDirectory(at: meetingRefDir, withIntermediateDirectories: true)

        // Load audio.
        let wavURL = bundleDir.appendingPathComponent("meetings/\(mid)/\(meta.audioFile)")
        let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: wavURL.path)

        // Plan or load existing plan.
        let planURL = meetingRefDir.appendingPathComponent("plan.json")
        let plan: ChunkPlan
        if !force, fm.fileExists(atPath: planURL.path) {
            plan = try JSONFiles.read(from: planURL)
        } else {
            let chunks = ChunkPlanner.plan(
                samples: samples,
                range: 0 ..< samples.count,
                targetSeconds: config.chunkSeconds
            )
            plan = ChunkPlan(chunks: chunks)
            try JSONFiles.write(plan, to: planURL)
        }

        let language = languageFromLocale(meta.appleLocale)
        var totalCost: Double = 0
        var wordsPresent: Bool?
        var completedChunks = 0

        for chunk in plan.chunks {
            // Check if this chunk is already completed (directly or via split).
            if !force, let metas = checkChunkCompletion(chunk: chunk, dir: meetingRefDir) {
                completedChunks += metas.count
                for cm in metas {
                    accumulateCost(
                        cm, dir: meetingRefDir,
                        totalCost: &totalCost, wordsPresent: &wordsPresent
                    )
                }
                continue
            }

            // Done-marker path for writing after success.
            let prefix = chunkFilePrefix(start: chunk.startSample, end: chunk.endSample)
            let doneURL = meetingRefDir.appendingPathComponent("\(prefix).done.json")

            // Build 16-bit WAV for this chunk.
            let wavData = WAVFile.int16WAVData(
                samples: samples,
                range: chunk.startSample ..< chunk.endSample
            )

            let request = TranscriptionRequest(
                model: config.model,
                wavData: wavData,
                language: language,
                zdr: config.zdr
            )

            let result = try await sendWithRetry(
                client: client,
                request: request,
                chunk: chunk,
                samples: samples,
                config: config,
                language: language,
                meetingRefDir: meetingRefDir,
                log: log,
                mid: mid
            )

            switch result {
            case let .success(chunkMetas):
                // Write plan-chunk completion marker for resume.
                try JSONFiles.write(chunkMetas, to: doneURL)

                for cm in chunkMetas {
                    completedChunks += 1
                    accumulateCost(
                        cm, dir: meetingRefDir,
                        totalCost: &totalCost, wordsPresent: &wordsPresent
                    )
                }
            case let .failure(error):
                return ReferenceStatus(
                    meetingID: mid, status: .failed, model: config.model,
                    zdr: config.zdr, chunkCount: plan.chunks.count,
                    completedChunks: completedChunks,
                    totalCost: totalCost > 0 ? totalCost : nil,
                    wordsPresent: wordsPresent,
                    error: error
                )
            case let .fatalStop(status, body):
                let bodyStr = String(data: body.prefix(500), encoding: .utf8) ?? ""
                let message: String
                if [401, 402, 403].contains(status) {
                    message = "Authentication/billing error (HTTP \(status)): \(bodyStr)"
                } else {
                    message = "Fatal API error (HTTP \(status)): \(bodyStr)"
                }
                // 401/402/403 stop the whole command (thrown as ReferenceRunnerError).
                if [401, 402, 403].contains(status) {
                    throw ReferenceRunnerError.fatalAPIError(
                        status: status, body: bodyStr, message: message
                    )
                }
                return ReferenceStatus(
                    meetingID: mid, status: .failed, model: config.model,
                    zdr: config.zdr, chunkCount: plan.chunks.count,
                    completedChunks: completedChunks,
                    totalCost: totalCost > 0 ? totalCost : nil,
                    wordsPresent: wordsPresent,
                    error: ErrorInfo(domain: "ReferenceRunner", code: status,
                                    description: message, debugDescription: message)
                )
            }
        }

        return ReferenceStatus(
            meetingID: mid, status: .completed, model: config.model,
            zdr: config.zdr, chunkCount: plan.chunks.count,
            completedChunks: completedChunks,
            totalCost: totalCost > 0 ? totalCost : nil,
            wordsPresent: wordsPresent
        )
    }

    // MARK: - Retry and split logic

    private enum ChunkResult {
        case success([ChunkMeta])
        case failure(ErrorInfo)
        case fatalStop(status: Int, body: Data)
    }

    /// Send a chunk with retry and split-on-timeout logic.
    ///
    /// Retry policy:
    /// - `retryable`: up to 4 retries with exponential backoff (2, 4, 8, 16 s).
    /// - `timeoutLike`: retry once, then split if depth < 3.
    /// - `fatal`: stop immediately.
    private static func sendWithRetry(
        client: OpenRouterClient,
        request: TranscriptionRequest,
        chunk: ChunkPlan.Chunk,
        samples: [Float],
        config: ReferenceConfig,
        language: String?,
        meetingRefDir: URL,
        log: RunLog,
        mid: String,
        splitDepth: Int = 0
    ) async throws -> ChunkResult {
        let maxRetries = 4
        let backoffBase: [UInt64] = [2, 4, 8, 16]
        var timeoutCount = 0

        for attempt in 0 ... maxRetries {
            let requestedAt = Date()
            let outcome = await client.transcribe(request)

            switch outcome {
            case let .success(status, headers, body):
                let latency = Date().timeIntervalSince(requestedAt)
                let chunkMeta = ChunkMeta(
                    chunkIndex: chunk.index,
                    startSample: chunk.startSample,
                    endSample: chunk.endSample,
                    startSeconds: chunk.startSeconds,
                    endSeconds: chunk.endSeconds,
                    requestMetadata: request.metadata(),
                    httpStatus: status,
                    responseHeaders: headers,
                    attempts: attempt + 1,
                    latencySeconds: latency,
                    requestedAt: requestedAt
                )
                let prefix = chunkFilePrefix(start: chunk.startSample, end: chunk.endSample)
                let responseURL = meetingRefDir.appendingPathComponent("\(prefix).response.json")
                let metaURL = meetingRefDir.appendingPathComponent("\(prefix).meta.json")
                try body.write(to: responseURL)
                try JSONFiles.write(chunkMeta, to: metaURL)
                return .success([chunkMeta])

            case let .retryable(status, retryHeaders, message):
                log.log("\(mid) chunk \(chunk.index): retryable (\(message)), "
                    + "attempt \(attempt + 1)/\(maxRetries + 1)")
                if attempt < maxRetries {
                    var delay = backoffBase[min(attempt, backoffBase.count - 1)]
                    // Honor Retry-After header (seconds form), capped at 60 s.
                    if let raStr = retryHeaders["Retry-After"] ?? retryHeaders["retry-after"],
                       let raSecs = UInt64(raStr)
                    {
                        delay = min(raSecs, 60)
                    }
                    try await Task.sleep(for: .seconds(delay))
                    continue
                }
                return .failure(ErrorInfo(
                    domain: "ReferenceRunner", code: status ?? -1,
                    description: "Retries exhausted: \(message)",
                    debugDescription: "Retries exhausted after \(maxRetries + 1) attempts: \(message)"
                ))

            case let .timeoutLike(status, message):
                timeoutCount += 1
                log.log("\(mid) chunk \(chunk.index): timeout-like (\(message)), count \(timeoutCount)")

                if timeoutCount <= 1 {
                    // Retry once.
                    try await Task.sleep(for: .seconds(2))
                    continue
                }

                // Split if depth allows.
                if splitDepth < 3 {
                    log.log("\(mid) chunk \(chunk.index): splitting at depth \(splitDepth + 1)")
                    return try await splitAndRetry(
                        chunk: chunk,
                        samples: samples,
                        config: config,
                        language: language,
                        client: client,
                        meetingRefDir: meetingRefDir,
                        log: log,
                        mid: mid,
                        splitDepth: splitDepth + 1
                    )
                }

                return .failure(ErrorInfo(
                    domain: "ReferenceRunner", code: status ?? -1,
                    description: "Timeouts exhausted (split depth \(splitDepth)): \(message)",
                    debugDescription: "Repeated timeouts at max split depth"
                ))

            case let .fatal(status, body):
                return .fatalStop(status: status, body: body)
            }
        }

        // Should not reach here, but handle gracefully.
        return .failure(ErrorInfo(
            domain: "ReferenceRunner", code: -1,
            description: "Unexpected retry loop exit",
            debugDescription: "Retry loop ended without result"
        ))
    }

    /// Split a chunk in half and retry each sub-chunk.
    private static func splitAndRetry(
        chunk: ChunkPlan.Chunk,
        samples: [Float],
        config: ReferenceConfig,
        language: String?,
        client: OpenRouterClient,
        meetingRefDir: URL,
        log: RunLog,
        mid: String,
        splitDepth: Int
    ) async throws -> ChunkResult {
        let halfTarget = Double(chunk.endSample - chunk.startSample) / 2.0 / 16000
        let subChunks = ChunkPlanner.plan(
            samples: samples,
            range: chunk.startSample ..< chunk.endSample,
            targetSeconds: halfTarget
        )

        var allMetas: [ChunkMeta] = []

        for sub in subChunks {
            // Sub-chunks keep their own start/end; file names use the
            // sample-range prefix so they never collide with plan chunks
            // or other sub-chunks.
            let wavData = WAVFile.int16WAVData(
                samples: samples,
                range: sub.startSample ..< sub.endSample
            )

            let request = TranscriptionRequest(
                model: config.model,
                wavData: wavData,
                language: language,
                zdr: config.zdr
            )

            let result = try await sendWithRetry(
                client: client,
                request: request,
                chunk: sub,
                samples: samples,
                config: config,
                language: language,
                meetingRefDir: meetingRefDir,
                log: log,
                mid: mid,
                splitDepth: splitDepth
            )

            switch result {
            case let .success(metas): allMetas.append(contentsOf: metas)
            case let .failure(error): return .failure(error)
            case let .fatalStop(status, body): return .fatalStop(status: status, body: body)
            }
        }

        return .success(allMetas)
    }

    // MARK: - Helpers

    /// Unique file prefix for a chunk based on its sample range.
    /// Guarantees no collision between plan chunks and sub-chunks from splits.
    static func chunkFilePrefix(start: Int, end: Int) -> String {
        "chunk_s\(start)_e\(end)"
    }

    /// Check if a plan chunk is already completed (directly or via split).
    ///
    /// Returns the completed chunk metas if found, or nil if the chunk needs processing.
    /// Checks the done-marker first (covers splits), then falls back to the chunk's
    /// own meta file (covers the race where the done-marker was not written yet).
    static func checkChunkCompletion(
        chunk: ChunkPlan.Chunk,
        dir: URL
    ) -> [ChunkMeta]? {
        let fm = FileManager.default
        let prefix = chunkFilePrefix(start: chunk.startSample, end: chunk.endSample)

        // Done marker (handles both split and non-split).
        let doneURL = dir.appendingPathComponent("\(prefix).done.json")
        if fm.fileExists(atPath: doneURL.path) {
            let savedMetas: [ChunkMeta]? = try? JSONFiles.read(from: doneURL)
            if let metas = savedMetas,
               !metas.isEmpty,
               metas.allSatisfy({ (200 ..< 300).contains($0.httpStatus) })
            {
                return metas
            }
        }

        // Fallback: the chunk's own response file.
        let metaURL = dir.appendingPathComponent("\(prefix).meta.json")
        let responseURL = dir.appendingPathComponent("\(prefix).response.json")
        if fm.fileExists(atPath: responseURL.path), fm.fileExists(atPath: metaURL.path) {
            let savedMeta: ChunkMeta? = try? JSONFiles.read(from: metaURL)
            if let savedMeta, (200 ..< 300).contains(savedMeta.httpStatus) {
                return [savedMeta]
            }
        }

        return nil
    }

    /// Read back cost and word-presence from a saved response file.
    private static func accumulateCost(
        _ meta: ChunkMeta,
        dir: URL,
        totalCost: inout Double,
        wordsPresent: inout Bool?
    ) {
        let prefix = chunkFilePrefix(start: meta.startSample, end: meta.endSample)
        let rURL = dir.appendingPathComponent("\(prefix).response.json")
        if let body = try? Data(contentsOf: rURL),
           let parsed = try? JSONDecoder().decode(ReferenceResponse.self, from: body)
        {
            if let cost = parsed.usage?.cost { totalCost += cost }
            if wordsPresent == nil { wordsPresent = parsed.words != nil }
        }
    }

    static func requireAPIKey() throws -> String {
        guard let key = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"],
              !key.isEmpty
        else {
            throw ReferenceRunnerError.apiKeyMissing
        }
        return key
    }

    /// Extract a two-letter language code from an Apple locale string (e.g. "en_US" -> "en").
    static func languageFromLocale(_ locale: String) -> String? {
        let code = locale.split(separator: "_").first.map(String.init)
        return code
    }

    static func isInteractiveTerminal() -> Bool {
        isatty(STDIN_FILENO) != 0
    }

    private static func readConsentFromStdin() -> Bool {
        guard let line = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() else {
            return false
        }
        return line == "y" || line == "yes"
    }
}
