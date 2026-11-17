#if canImport(Speech)
    import AVFoundation
    import CoreMedia
    import Foundation
    import os.log
    import Speech
    import WhisperKit

    /// Runs Apple `SpeechTranscriber` on merged audio and returns
    /// `[TranscriptionResult]` (WhisperKit type) via `AppleWordGrouping`.
    ///
    /// Port of `experiments/STTLab/Sources/STTLabRunner/AppleTranscription.swift`,
    /// minus the experiment bookkeeping.
    @available(macOS 26, *)
    enum AppleSpeechSTT {
        private static let log = Logger(
            subsystem: "net.scosman.biscotti",
            category: "AppleSpeech"
        )

        /// Transcribe 16 kHz mono float samples using Apple Speech.
        ///
        /// - Parameters:
        ///   - samples: PCM float samples at 16 kHz.
        ///   - duration: Audio duration in seconds (for the watchdog timeout).
        ///   - locale: Locale identifier (e.g. "en_US").
        ///   - status: Callback for status messages during asset downloads.
        /// - Returns: WhisperKit `[TranscriptionResult]` bridged from Apple output.
        static func transcribe(
            samples: [Float],
            duration: TimeInterval,
            locale: String,
            status: @escaping @Sendable (String) -> Void
        ) async throws -> [TranscriptionResult] {
            let (transcriber, resolvedLocale) = try await prepareTranscriber(
                locale: locale, status: status
            )

            let results = try await runAnalysis(
                transcriber: transcriber, samples: samples, duration: duration
            )

            log.info(
                "Apple transcription complete: \(results.count) results from \(String(format: "%.1f", duration))s audio"
            )

            return AppleWordGrouping.transcriptionResults(
                from: results,
                language: resolvedLocale
            )
        }

        // MARK: - Setup

        /// Resolve locale, prepare the transcriber, and install assets if needed.
        private static func prepareTranscriber(
            locale: String,
            status: @escaping @Sendable (String) -> Void
        ) async throws -> (SpeechTranscriber, String) {
            let requestedLocale = Locale(identifier: locale)
            guard let resolvedLocale = await SpeechTranscriber.supportedLocale(
                equivalentTo: requestedLocale
            ) else {
                throw TranscriptionError.engineUnavailable(
                    "Locale \(locale) is not supported by Apple Speech"
                )
            }

            let transcriber = try await AppleLocaleReservations.prepare(
                locale: resolvedLocale
            )

            if let request = try await AssetInventory.assetInstallationRequest(
                supporting: [transcriber]
            ) {
                status("Downloading Apple speech model")
                do {
                    try await request.downloadAndInstall()
                } catch {
                    throw TranscriptionError.downloadFailed(
                        "Apple speech assets: \(error.localizedDescription)"
                    )
                }
            }

            return (transcriber, resolvedLocale.identifier)
        }

        // MARK: - Analysis

        /// Write the WAV, run the analyzer, collect results with a watchdog timeout.
        private static func runAnalysis(
            transcriber: SpeechTranscriber,
            samples: [Float],
            duration: TimeInterval
        ) async throws -> [AppleResultInput] {
            let url = try WAVWriter.writeTemp(samples)
            defer { try? FileManager.default.removeItem(at: url) }
            let file = try AVAudioFile(forReading: url)

            let analyzer = SpeechAnalyzer(modules: [transcriber])

            let collector = Task<[AppleResultInput], any Error> {
                var out: [AppleResultInput] = []
                for try await result in transcriber.results where result.isFinal {
                    out.append(extractResultInput(result))
                }
                return out
            }

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
                throw TranscriptionError.transcriptionFailed(
                    "Apple Speech analysis failed: \(error.localizedDescription)"
                )
            }

            return try await collectWithWatchdog(
                collector: collector, duration: duration
            )
        }

        /// Wait for the collector task with a timeout based on audio duration.
        private static func collectWithWatchdog(
            collector: Task<[AppleResultInput], any Error>,
            duration: TimeInterval
        ) async throws -> [AppleResultInput] {
            let timeoutSeconds = max(600, duration)
            do {
                return try await withThrowingTaskGroup(
                    of: [AppleResultInput].self
                ) { group in
                    group.addTask { try await collector.value }
                    group.addTask {
                        try await Task.sleep(for: .seconds(timeoutSeconds))
                        throw TranscriptionError.transcriptionFailed(
                            "Apple Speech timed out after \(Int(timeoutSeconds))s"
                        )
                    }
                    // Both tasks always produce a value or throw, so next() is non-nil.
                    guard let first = try await group.next() else {
                        throw TranscriptionError.transcriptionFailed(
                            "Apple Speech collector returned no results"
                        )
                    }
                    group.cancelAll()
                    return first
                }
            } catch let error as TranscriptionError {
                collector.cancel()
                throw error
            } catch {
                collector.cancel()
                throw TranscriptionError.transcriptionFailed(
                    "Apple Speech failed: \(error.localizedDescription)"
                )
            }
        }

        // MARK: - Result extraction

        /// Convert a `SpeechTranscriber.Result` into the plain-data
        /// `AppleResultInput` for the word grouper.
        private static func extractResultInput(
            _ result: SpeechTranscriber.Result
        ) -> AppleResultInput {
            let text = String(result.text.characters)
            let runs = extractRuns(from: result.text)

            return AppleResultInput(
                text: text,
                rangeStart: result.range.start.seconds,
                rangeDuration: result.range.duration.seconds,
                runs: runs
            )
        }

        /// Extract attributed runs from an `AttributedString`, converting
        /// `audioTimeRange` and `transcriptionConfidence` into plain values.
        private static func extractRuns(
            from attrStr: AttributedString
        ) -> [AppleRunInput] {
            var result: [AppleRunInput] = []
            let characters = attrStr.characters

            for run in attrStr.runs {
                let runText = String(attrStr[run.range].characters)
                let charOffset = characters.distance(
                    from: characters.startIndex, to: run.range.lowerBound
                )
                let charLength = characters.distance(
                    from: run.range.lowerBound, to: run.range.upperBound
                )

                let timeRange: CMTimeRange? = run.audioTimeRange
                let confidence: Double? = run.transcriptionConfidence

                let startSeconds: Double? = if let timeRange, timeRange.start.isNumeric {
                    timeRange.start.seconds
                } else {
                    nil
                }
                let durationSeconds: Double? = if let timeRange, timeRange.duration.isNumeric {
                    timeRange.duration.seconds
                } else {
                    nil
                }

                result.append(AppleRunInput(
                    text: runText,
                    charOffset: charOffset,
                    charLength: charLength,
                    start: startSeconds,
                    duration: durationSeconds,
                    confidence: confidence
                ))
            }
            return result
        }
    }
#endif
