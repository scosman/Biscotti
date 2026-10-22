import AVFoundation
import CoreMedia
import Foundation
import STTLabCore

#if canImport(Speech)
    import Speech
#endif

/// Wraps Apple SpeechTranscriber for a single meeting file.
/// All Speech code is behind `@available(macOS 26, *)`.
@available(macOS 26, *)
enum AppleTranscription {

    // MARK: - Public entry points

    /// Whether SpeechTranscriber is available on this system.
    static var isAvailable: Bool {
        SpeechTranscriber.isAvailable
    }

    /// Supported locale identifiers (async).
    static func supportedLocaleIdentifiers() async -> [String] {
        await SpeechTranscriber.supportedLocales.map(\.identifier)
    }

    /// Installed locale identifiers (async).
    static func installedLocaleIdentifiers() async -> [String] {
        await SpeechTranscriber.installedLocales.map(\.identifier)
    }

    /// Transcribe a single meeting audio file.
    /// - Returns: A completed or unsupportedLocale result.
    /// - Throws: On infrastructure failure (the caller catches and writes a failed result).
    static func transcribe(
        meta: MeetingMeta,
        audioURL: URL,
        bundleID: UUID,
        log: RunLog,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> AppleMeetingResult {
        // 1. Check locale support
        let requestedLocale = Locale(identifier: meta.appleLocale)
        guard let resolvedLocale = await SpeechTranscriber.supportedLocale(
            equivalentTo: requestedLocale
        ) else {
            return AppleMeetingResult(
                bundleID: bundleID,
                meetingID: meta.meetingID,
                status: .unsupportedLocale,
                requestedLocale: meta.appleLocale,
                config: AppleConfig(),
                audioDurationSeconds: meta.durationSeconds
            )
        }

        // 2. Create transcriber
        let transcriber = SpeechTranscriber(
            locale: resolvedLocale,
            transcriptionOptions: [],
            reportingOptions: [.alternativeTranscriptions],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )

        // 3. Asset installation
        var assetEvent = AssetEvent(installNeeded: false)
        do {
            if let request = try await AssetInventory.assetInstallationRequest(
                supporting: [transcriber]
            ) {
                assetEvent.installNeeded = true
                assetEvent.startedAt = Date()
                log.log("Downloading Apple speech assets for \(resolvedLocale.identifier)")
                do {
                    try await request.downloadAndInstall()
                    assetEvent.finishedAt = Date()
                    assetEvent.progressTotalUnitCount = request.progress.totalUnitCount
                } catch {
                    assetEvent.finishedAt = Date()
                    assetEvent.error = ErrorInfo(error)
                    return AppleMeetingResult(
                        bundleID: bundleID,
                        meetingID: meta.meetingID,
                        status: .failed,
                        requestedLocale: meta.appleLocale,
                        resolvedLocale: resolvedLocale.identifier,
                        config: AppleConfig(),
                        assets: assetEvent,
                        audioDurationSeconds: meta.durationSeconds,
                        error: ErrorInfo(error)
                    )
                }
            }
        } catch {
            assetEvent.error = ErrorInfo(error)
            return AppleMeetingResult(
                bundleID: bundleID,
                meetingID: meta.meetingID,
                status: .failed,
                requestedLocale: meta.appleLocale,
                resolvedLocale: resolvedLocale.identifier,
                config: AppleConfig(),
                assets: assetEvent,
                audioDurationSeconds: meta.durationSeconds,
                error: ErrorInfo(error)
            )
        }

        // 4. Open the audio file
        let file = try AVAudioFile(forReading: audioURL)
        let duration = Double(file.length) / file.fileFormat.sampleRate

        // 5. Create analyzer
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // 6. Start memory sampler
        let sampler = MemorySampler(interval: 0.5, watchSystemProcesses: true)
        await sampler.start()
        let analysisStart = Date()

        // 7. Start collector before analysis
        let collector = Task<[AppleResult], any Error> {
            var out: [AppleResult] = []
            for try await r in transcriber.results {
                let finTime = r.resultsFinalizationTime.seconds
                let fraction = duration > 0 ? finTime / duration : 0
                progress(min(fraction, 1.0))
                out.append(convertResult(r, index: out.count))
            }
            return out
        }

        // 8. Run analysis
        do {
            let last = try await analyzer.analyzeSequence(from: file)
            if let last {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collector.cancel()
            await analyzer.cancelAndFinishNow()
            _ = await sampler.stop()
            throw error
        }

        // 9. Watchdog: wait for collector with timeout
        let timeoutSeconds = max(600, duration)
        let results: [AppleResult]
        do {
            results = try await withThrowingTaskGroup(of: [AppleResult].self) { group in
                group.addTask {
                    try await collector.value
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeoutSeconds))
                    throw RunnerJobError.appleTimeout(meetingID: meta.meetingID, partialResults: 0)
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
        } catch {
            collector.cancel()
            _ = await sampler.stop()
            throw error
        }

        // 10. Build completed result
        let analysisEnd = Date()
        let memory = await sampler.stop()

        return AppleMeetingResult(
            bundleID: bundleID,
            meetingID: meta.meetingID,
            status: .completed,
            requestedLocale: meta.appleLocale,
            resolvedLocale: resolvedLocale.identifier,
            config: AppleConfig(),
            assets: assetEvent.installNeeded ? assetEvent : nil,
            timing: TimedRun(start: analysisStart, end: analysisEnd),
            audioDurationSeconds: duration,
            memory: memory,
            results: results
        )
    }

    // MARK: - Conversion

    /// Convert a SpeechTranscriber.Result to our serializable AppleResult.
    private static func convertResult(
        _ r: SpeechTranscriber.Result,
        index: Int
    ) -> AppleResult {
        let text = String(r.text.characters)
        let runs = extractRuns(from: r.text)
        let alternatives = r.alternatives.map { alt in
            AppleAlternative(
                text: String(alt.characters),
                runs: extractRuns(from: alt)
            )
        }

        return AppleResult(
            index: index,
            rangeStart: STTLabCore.CMTimeValue(from: r.range.start),
            rangeDuration: STTLabCore.CMTimeValue(from: r.range.duration),
            resultsFinalizationTime: STTLabCore.CMTimeValue(from: r.resultsFinalizationTime),
            isFinal: r.isFinal,
            text: text,
            runs: runs,
            alternatives: alternatives
        )
    }

    /// Extract attributed runs from an AttributedString.
    private static func extractRuns(from attrStr: AttributedString) -> [AppleRun] {
        var result: [AppleRun] = []
        let characters = attrStr.characters

        for run in attrStr.runs {
            let runText = String(attrStr[run.range].characters)
            let charOffset = characters.distance(from: characters.startIndex, to: run.range.lowerBound)
            let charLength = characters.distance(from: run.range.lowerBound, to: run.range.upperBound)

            let timeRange: CMTimeRange? = run.audioTimeRange
            let confidence: Double? = run.transcriptionConfidence

            let attributesDebug = String(describing: run.attributes)

            result.append(AppleRun(
                text: runText,
                charOffset: charOffset,
                charLength: charLength,
                timeStart: timeRange.map { STTLabCore.CMTimeValue(from: $0.start) },
                timeDuration: timeRange.map { STTLabCore.CMTimeValue(from: $0.duration) },
                confidence: confidence,
                attributesDebug: attributesDebug
            ))
        }
        return result
    }
}

// MARK: - CMTimeValue convenience

extension STTLabCore.CMTimeValue {
    /// Create from a CoreMedia CMTime.
    init(from cmTime: CMTime) {
        self.init(
            value: cmTime.value,
            timescale: cmTime.timescale,
            flags: cmTime.flags.rawValue,
            epoch: Int64(cmTime.epoch),
            seconds: cmTime.isNumeric ? cmTime.seconds : nil
        )
    }
}
