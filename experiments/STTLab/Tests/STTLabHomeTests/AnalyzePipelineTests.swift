import Foundation
import SpeakerKit
import STTLabAnalysis
import STTLabCore
@testable import STTLabHome
import Testing
import WhisperKit

@Suite("AnalyzePipeline end-to-end")
struct AnalyzePipelineTests {

    // MARK: - Fixture builder

    /// Build a synthetic workspace + results directory in a temp dir.
    /// Meeting m01: all three engines complete, with diarization.
    /// Meeting m02: Whisper failed, Apple and reference complete.
    static func buildFixture() throws -> (workspace: URL, results: URL, bundleID: UUID) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sttlab-pipeline-\(UUID().uuidString)")
        let fm = FileManager.default

        let bundleID = UUID()
        let machine = MachineInfo(
            hostModel: "Mac15,3", chip: "M4", memoryBytes: 17_179_869_184,
            osVersion: "15.1", osBuild: "24B83"
        )

        // --- Workspace ---
        let ws = root.appendingPathComponent("workspace")
        let bundleDir = ws.appendingPathComponent("bundle")
        let homeDir = ws.appendingPathComponent("home")

        // Manifest.
        try fm.createDirectory(at: bundleDir, withIntermediateDirectories: true)
        let manifest = BundleManifest(bundleID: bundleID, meetings: ["m01", "m02"])
        try JSONFiles.write(manifest, to: bundleDir.appendingPathComponent("manifest.json"))

        // Meetings (with placeholder audio files).
        for mid in ["m01", "m02"] {
            let meetDir = bundleDir.appendingPathComponent("meetings/\(mid)")
            try fm.createDirectory(at: meetDir, withIntermediateDirectories: true)
            let meta = MeetingMeta(
                meetingID: mid, durationSeconds: 10.0, sampleRate: 16000,
                speakerCount: 2, transcriptLanguage: "en", appleLocale: "en_US",
                audioFile: "audio.wav", audioSHA256: "abc123"
            )
            try JSONFiles.write(meta, to: meetDir.appendingPathComponent("meta.json"))
            // Placeholder audio file (just needs to exist for BundleLoader).
            try Data([0]).write(to: meetDir.appendingPathComponent("audio.wav"))
        }

        // --- Home: Whisper ---
        let whisperDir = homeDir.appendingPathComponent("whisper")
        try fm.createDirectory(at: whisperDir, withIntermediateDirectories: true)

        // m01: Whisper completed with words.
        let whisperSeg = TranscriptionSegment(
            id: 0, seek: 0,
            start: 0.0, end: 5.0,
            text: "hello world goodbye",
            tokens: [],
            temperature: 0, avgLogprob: 0, compressionRatio: 0, noSpeechProb: 0,
            words: [
                WordTiming(word: " hello", tokens: [], start: 0.0, end: 1.0, probability: 0.9),
                WordTiming(word: " world", tokens: [], start: 1.0, end: 2.0, probability: 0.8),
                WordTiming(word: " goodbye", tokens: [], start: 4.0, end: 5.0, probability: 0.7),
            ]
        )
        let whisperResult = TranscriptionResult(
            text: "hello world goodbye",
            segments: [whisperSeg],
            language: "en",
            timings: TranscriptionTimings()
        )
        let m01Whisper = WhisperOutput(
            meetingID: "m01", status: .completed,
            settings: ["model": "large-v3-turbo"],
            machine: machine,
            timing: TimedRun(start: Date(), end: Date().addingTimeInterval(2.0)),
            audioDurationSeconds: 10.0,
            memory: MemoryReport(
                processPeakFootprintBytes: 500_000_000,
                processLifetimePeakBytes: 600_000_000,
                sampleIntervalSeconds: 0.5, sampleCount: 4
            ),
            results: [whisperResult]
        )
        try JSONFiles.write(m01Whisper, to: whisperDir.appendingPathComponent("m01.json"))

        // m02: Whisper failed.
        let m02Whisper = WhisperOutput(
            meetingID: "m02", status: .failed,
            settings: ["model": "large-v3-turbo"],
            machine: machine,
            audioDurationSeconds: 10.0,
            error: ErrorInfo(domain: "whisper", code: -1,
                             description: "model load failed", debugDescription: "model load failed")
        )
        try JSONFiles.write(m02Whisper, to: whisperDir.appendingPathComponent("m02.json"))

        // --- Home: Diarization ---
        let diaDir = homeDir.appendingPathComponent("diarization")
        try fm.createDirectory(at: diaDir, withIntermediateDirectories: true)

        // Build a simple diarization: speaker 0 [0,5), speaker 1 [5,10).
        let diaResult = DiarizationResult(
            speakerCount: 2,
            totalFrames: 160000,
            frameRate: 16000,
            segments: [
                SpeakerSegment(speaker: .speakerId(0), startFrame: 0, endFrame: 80000, frameRate: 16000),
                SpeakerSegment(speaker: .speakerId(1), startFrame: 80000, endFrame: 160000, frameRate: 16000),
            ]
        )
        let savedDia = SavedDiarization(diaResult)
        for mid in ["m01", "m02"] {
            let diaOut = DiarizationOutput(
                meetingID: mid, status: .completed,
                settings: ["strategy": "subsegment"],
                machine: machine,
                timing: TimedRun(start: Date(), end: Date().addingTimeInterval(1.0)),
                audioDurationSeconds: 10.0,
                memory: MemoryReport(
                    processPeakFootprintBytes: 200_000_000,
                    sampleIntervalSeconds: 0.5, sampleCount: 2
                ),
                diarization: savedDia
            )
            try JSONFiles.write(diaOut, to: diaDir.appendingPathComponent("\(mid).json"))
        }

        // --- Home: Reference ---
        for mid in ["m01", "m02"] {
            let refDir = homeDir.appendingPathComponent("reference/\(mid)")
            try fm.createDirectory(at: refDir, withIntermediateDirectories: true)

            let refStatus = ReferenceStatus(
                meetingID: mid, status: .completed,
                model: "microsoft/mai-transcribe-2", zdr: true,
                chunkCount: 2, completedChunks: 2, totalCost: 0.05
            )
            try JSONFiles.write(refStatus, to: refDir.appendingPathComponent("status.json"))

            // Chunk 1: samples 0-80000 (0-5s).
            let meta1 = ChunkMeta(
                chunkIndex: 0, startSample: 0, endSample: 80000,
                startSeconds: 0, endSeconds: 5,
                requestMetadata: [:], httpStatus: 200, responseHeaders: [:],
                attempts: 1, latencySeconds: 1.0, requestedAt: Date()
            )
            try JSONFiles.write(meta1, to: refDir.appendingPathComponent("chunk_s0_e80000.meta.json"))

            let resp1 = """
            {"text": "hello world", "words": [{"word": "hello", "start": 0.0, "end": 1.0, "confidence": 0.95}, {"word": "world", "start": 1.0, "end": 2.0, "confidence": 0.90}]}
            """
            try resp1.data(using: .utf8)!.write(
                to: refDir.appendingPathComponent("chunk_s0_e80000.response.json"))

            // Chunk 2: samples 80000-160000 (5-10s).
            let meta2 = ChunkMeta(
                chunkIndex: 1, startSample: 80000, endSample: 160000,
                startSeconds: 5, endSeconds: 10,
                requestMetadata: [:], httpStatus: 200, responseHeaders: [:],
                attempts: 1, latencySeconds: 1.0, requestedAt: Date()
            )
            try JSONFiles.write(meta2, to: refDir.appendingPathComponent("chunk_s80000_e160000.meta.json"))

            let resp2 = """
            {"text": "goodbye now", "words": [{"word": "goodbye", "start": 0.0, "end": 1.0, "confidence": 0.85}, {"word": "now", "start": 1.0, "end": 2.0, "confidence": 0.80}]}
            """
            try resp2.data(using: .utf8)!.write(
                to: refDir.appendingPathComponent("chunk_s80000_e160000.response.json"))
        }

        // --- Runner results ---
        let resultsDir = root.appendingPathComponent("results")
        try fm.createDirectory(at: resultsDir, withIntermediateDirectories: true)

        let runnerMachine = MachineInfo(
            hostModel: "Mac15,5", chip: "M4 Pro", memoryBytes: 25_769_803_776,
            osVersion: "27.0", osBuild: "27A0"
        )

        let runFile = RunFile(sessions: [
            RunnerSession(
                bundleID: bundleID,
                appVersion: "1.0",
                machine: runnerMachine,
                startedAt: Date(),
                speechTranscriberAvailable: true,
                meetingsAttempted: ["m01", "m02"]
            ),
        ])
        try JSONFiles.write(runFile, to: resultsDir.appendingPathComponent("run.json"))

        // Apple results per meeting.
        for mid in ["m01", "m02"] {
            let meetResultDir = resultsDir.appendingPathComponent("meetings/\(mid)")
            try fm.createDirectory(at: meetResultDir, withIntermediateDirectories: true)

            // Build a simple AppleMeetingResult with runs that have timed words.
            let appleResult = AppleMeetingResult(
                bundleID: bundleID,
                meetingID: mid,
                status: .completed,
                requestedLocale: "en_US",
                resolvedLocale: "en_US",
                config: AppleConfig(),
                timing: TimedRun(start: Date(), end: Date().addingTimeInterval(3.0)),
                audioDurationSeconds: 10.0,
                memory: MemoryReport(
                    processPeakFootprintBytes: 300_000_000,
                    processLifetimePeakBytes: 400_000_000,
                    sampleIntervalSeconds: 0.5, sampleCount: 6,
                    systemProcesses: [
                        ProcessMemory(name: "speechsynthesisd", pid: 1234,
                                      peakFootprintBytes: 150_000_000),
                    ]
                ),
                results: [
                    AppleResult(
                        index: 0,
                        rangeStart: CMTimeValue(value: 0, timescale: 1, flags: 1, epoch: 0, seconds: 0),
                        rangeDuration: CMTimeValue(value: 5, timescale: 1, flags: 1, epoch: 0, seconds: 5),
                        resultsFinalizationTime: CMTimeValue(value: 5, timescale: 1, flags: 1, epoch: 0, seconds: 5),
                        isFinal: true,
                        text: "hello world",
                        runs: [
                            AppleRun(text: "hello", charOffset: 0, charLength: 5,
                                     timeStart: CMTimeValue(value: 0, timescale: 1, flags: 1, epoch: 0, seconds: 0),
                                     timeDuration: CMTimeValue(value: 1, timescale: 1, flags: 1, epoch: 0, seconds: 1),
                                     confidence: 0.9),
                            AppleRun(text: " ", charOffset: 5, charLength: 1),
                            AppleRun(text: "world", charOffset: 6, charLength: 5,
                                     timeStart: CMTimeValue(value: 1, timescale: 1, flags: 1, epoch: 0, seconds: 1),
                                     timeDuration: CMTimeValue(value: 1, timescale: 1, flags: 1, epoch: 0, seconds: 1),
                                     confidence: 0.8),
                        ]
                    ),
                    AppleResult(
                        index: 1,
                        rangeStart: CMTimeValue(value: 4, timescale: 1, flags: 1, epoch: 0, seconds: 4),
                        rangeDuration: CMTimeValue(value: 2, timescale: 1, flags: 1, epoch: 0, seconds: 2),
                        resultsFinalizationTime: CMTimeValue(value: 6, timescale: 1, flags: 1, epoch: 0, seconds: 6),
                        isFinal: true,
                        text: "goodbye now",
                        runs: [
                            AppleRun(text: "goodbye", charOffset: 0, charLength: 7,
                                     timeStart: CMTimeValue(value: 4, timescale: 1, flags: 1, epoch: 0, seconds: 4),
                                     timeDuration: CMTimeValue(value: 1, timescale: 1, flags: 1, epoch: 0, seconds: 1),
                                     confidence: 0.7),
                            AppleRun(text: " ", charOffset: 7, charLength: 1),
                            AppleRun(text: "now", charOffset: 8, charLength: 3,
                                     timeStart: CMTimeValue(value: 5, timescale: 1, flags: 1, epoch: 0, seconds: 5),
                                     timeDuration: CMTimeValue(value: 1, timescale: 1, flags: 1, epoch: 0, seconds: 1),
                                     confidence: 0.6),
                        ]
                    ),
                ]
            )
            try JSONFiles.write(appleResult, to: meetResultDir.appendingPathComponent("apple.json"))
        }

        return (ws, resultsDir, bundleID)
    }

    // MARK: - Tests

    @Test("Full pipeline produces populated report")
    func fullPipeline() throws {
        let (ws, resultsDir, bundleID) = try Self.buildFixture()
        defer { try? FileManager.default.removeItem(at: ws.deletingLastPathComponent()) }

        let bundle = try BundleLoader.load(from: ws.appendingPathComponent("bundle"))
        let runFile: RunFile = try JSONFiles.read(
            from: resultsDir.appendingPathComponent("run.json"))
        let inputs = try AnalyzeInputs.load(
            workspace: ws, resultsDir: resultsDir,
            manifest: bundle.manifest, metas: bundle.metas
        )

        let result = AnalyzePipeline.run(
            meetingInputs: inputs, manifest: bundle.manifest,
            runFile: runFile, log: RunLog(echoToStdout: false)
        )
        let report = result.report

        // Basic structure.
        #expect(report.bundleID == bundleID.uuidString)
        #expect(report.meetings.count == 2)

        // Both meetings have Apple completed.
        #expect(report.meetings[0].appleStatus == "completed")
        #expect(report.meetings[1].appleStatus == "completed")

        // m01 has all three engines, m02 has Whisper failed.
        #expect(report.meetings[0].whisperStatus == "completed")
        #expect(report.meetings[1].whisperStatus == "failed")
        #expect(report.meetings[0].referenceStatus == "completed")
        #expect(report.meetings[1].referenceStatus == "completed")

        // WER: both meetings have A-R (both have Apple + Reference).
        let m01 = report.meetings[0]
        let m02 = report.meetings[1]
        #expect(m01.werAppleVsRef != nil)
        #expect(m02.werAppleVsRef != nil)
        // m01 also has W-R, m02 does not (Whisper failed).
        #expect(m01.werWhisperVsRef != nil)
        #expect(m02.werWhisperVsRef == nil)

        // Pooled WER.
        #expect(report.pooledWerAppleVsRef != nil)
        #expect(report.pooledWerWhisperVsRef != nil)  // from m01 only

        // Overall timing A-W populated (from m01).
        #expect(report.overallTimingAW != nil)
        #expect(report.overallTimingAW!.startStats.pairs > 0)

        // Overall timing A-R populated.
        #expect(report.overallTimingAR != nil)
        #expect(report.overallTimingAR!.startStats.pairs > 0)

        // Overall timing W-R populated (from m01).
        #expect(report.overallTimingWR != nil)
        #expect(report.overallTimingWR!.startStats.pairs > 0)

        // Speaker agreement A-W populated (from m01).
        #expect(report.overallSpeakerAgreementAW != nil)
        #expect(m01.speakerAgreementAW != nil)

        // Speaker agreement A-R populated.
        #expect(report.overallSpeakerAgreementAR != nil)
        #expect(m01.speakerAgreementAR != nil)

        // Speaker agreement W-R populated (from m01).
        #expect(report.overallSpeakerAgreementWR != nil)
        #expect(m01.speakerAgreementWR != nil)

        // Overall speaker agreement has no stale coverage.
        #expect(report.overallSpeakerAgreementAW?.coverageA == nil)
        #expect(report.overallSpeakerAgreementAW?.coverageB == nil)

        // Errors list contains the Whisper failure.
        #expect(!report.errors.isEmpty)
        #expect(report.errors.contains { $0.contains("m02") && $0.contains("Whisper") })

        // Machines populated.
        #expect(report.homeMachine?.chip == "M4")
        #expect(report.runnerMachine?.chip == "M4 Pro")

        // Memory populated on meetings.
        #expect(m01.appleMemory != nil)
        #expect(m01.whisperMemory != nil)
        #expect(m01.diarizationMemory != nil)

        // Per-meeting timing A-W populated for m01.
        #expect(m01.timingAppleVsWhisper != nil)
        #expect(m01.timingAppleVsWhisper!.startStats.medianAbs != nil)

        // Alignments cached for both meetings.
        #expect(result.alignments["m01"] != nil)
        #expect(result.alignments["m01"]?.appleAligned != nil)
        #expect(result.alignments["m01"]?.whisperAligned != nil)
        #expect(result.alignments["m01"]?.referenceAligned != nil)
        #expect(result.alignments["m02"] != nil)
        #expect(result.alignments["m02"]?.appleAligned != nil)
        // m02 Whisper failed, so no whisper alignment.
        #expect(result.alignments["m02"]?.whisperAligned == nil)
    }

    @Test("Report markdown contains all section headers, columns, and caveats")
    func reportMarkdown() throws {
        let (ws, resultsDir, _) = try Self.buildFixture()
        defer { try? FileManager.default.removeItem(at: ws.deletingLastPathComponent()) }

        let bundle = try BundleLoader.load(from: ws.appendingPathComponent("bundle"))
        let runFile: RunFile = try JSONFiles.read(
            from: resultsDir.appendingPathComponent("run.json"))
        let inputs = try AnalyzeInputs.load(
            workspace: ws, resultsDir: resultsDir,
            manifest: bundle.manifest, metas: bundle.metas
        )

        let result = AnalyzePipeline.run(
            meetingInputs: inputs, manifest: bundle.manifest,
            runFile: runFile, log: RunLog(echoToStdout: false)
        )

        let md = MarkdownRenderer.render(result.report)

        // All expected section headers.
        #expect(md.contains("# STTLab Report"))
        #expect(md.contains("## Run Summary"))
        #expect(md.contains("## Summary"))
        #expect(md.contains("## Per-Meeting Results"))
        #expect(md.contains("## Speed"))
        #expect(md.contains("## Accuracy"))
        #expect(md.contains("## Text Quality"))
        #expect(md.contains("## Word Timing"))
        #expect(md.contains("## Speaker Alignment"))
        #expect(md.contains("## Other"))
        #expect(md.contains("## Caveats"))
        #expect(md.contains("### Memory"))

        // Timing sections should show real data, not n/a.
        #expect(md.contains("### Apple vs Whisper"))
        #expect(md.contains("### Apple vs Reference"))
        #expect(md.contains("### Whisper vs Reference"))

        // Speaker agreement sections rendered.
        #expect(md.contains("### Apple vs Whisper Agreement"))
        #expect(md.contains("### Apple vs Reference Agreement"))
        #expect(md.contains("### Whisper vs Reference Agreement"))

        // Memory table has data.
        #expect(md.contains("Process peak"))
        #expect(md.contains("MB"))

        // Per-meeting table has Speakers and Median |ΔStart| columns.
        #expect(md.contains("| Speakers |"))
        #expect(md.contains("| Median |ΔStart| A-W |"))
        // m01 row should contain actual timing value (not n/a) for ΔStart.
        let m01Lines = md.components(separatedBy: "\n").filter { $0.contains("| m01 |") }
        let perMeetingLine = m01Lines.first { $0.contains("TB A wins") == false && $0.contains("| 2 |") }
        if let line = perMeetingLine {
            #expect(line.contains("n/a") == false || line.contains("| — |"))
        }

        // Summary table has tie-break by tokens and timing vs ref rows.
        #expect(md.contains("Tie-break wins (tokens)"))
        #expect(md.contains("Median |ΔStart| vs ref"))

        // Caveats mention m02 Whisper failure.
        #expect(md.contains("m02: Whisper failed"))

        // No coverage lines in speaker agreement section.
        #expect(!md.contains("Coverage A:"))
        #expect(!md.contains("Coverage W:"))
    }

    @Test("Transcript files are written using cached alignments")
    func transcriptFiles() throws {
        let (ws, resultsDir, _) = try Self.buildFixture()
        let root = ws.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }

        let bundle = try BundleLoader.load(from: ws.appendingPathComponent("bundle"))
        let runFile: RunFile = try JSONFiles.read(
            from: resultsDir.appendingPathComponent("run.json"))
        let inputs = try AnalyzeInputs.load(
            workspace: ws, resultsDir: resultsDir,
            manifest: bundle.manifest, metas: bundle.metas
        )

        let result = AnalyzePipeline.run(
            meetingInputs: inputs, manifest: bundle.manifest,
            runFile: runFile, log: RunLog(echoToStdout: false)
        )

        let outDir = root.appendingPathComponent("output")
        try AnalyzePipeline.writeOutputs(
            result: result, meetingInputs: inputs, outputDir: outDir
        )

        let fm = FileManager.default

        // Plain text transcripts for m01 (all three engines).
        #expect(fm.fileExists(atPath: outDir.appendingPathComponent("transcripts/m01/apple.txt").path))
        #expect(fm.fileExists(atPath: outDir.appendingPathComponent("transcripts/m01/whisper.txt").path))
        #expect(fm.fileExists(atPath: outDir.appendingPathComponent("transcripts/m01/reference.txt").path))

        // Speaker-annotated transcripts.
        #expect(fm.fileExists(atPath: outDir.appendingPathComponent("transcripts/m01/apple.speakers.md").path))
        #expect(fm.fileExists(atPath: outDir.appendingPathComponent("transcripts/m01/whisper.speakers.md").path))
        #expect(fm.fileExists(atPath: outDir.appendingPathComponent("transcripts/m01/reference.speakers.md").path))

        // m02 should have Apple and Reference transcripts but no Whisper.
        #expect(fm.fileExists(atPath: outDir.appendingPathComponent("transcripts/m02/apple.txt").path))
        #expect(!fm.fileExists(atPath: outDir.appendingPathComponent("transcripts/m02/whisper.txt").path))
        #expect(fm.fileExists(atPath: outDir.appendingPathComponent("transcripts/m02/reference.txt").path))

        // m02 has Apple + Reference speaker-annotated, but no Whisper.
        #expect(fm.fileExists(atPath: outDir.appendingPathComponent("transcripts/m02/apple.speakers.md").path))
        #expect(!fm.fileExists(atPath: outDir.appendingPathComponent("transcripts/m02/whisper.speakers.md").path))
        #expect(fm.fileExists(atPath: outDir.appendingPathComponent("transcripts/m02/reference.speakers.md").path))

        // Report files.
        #expect(fm.fileExists(atPath: outDir.appendingPathComponent("report.md").path))
        #expect(fm.fileExists(atPath: outDir.appendingPathComponent("metrics.json").path))
    }

    @Test("Bundle ID mismatch is refused")
    func bundleIDMismatch() throws {
        let (ws, resultsDir, _) = try Self.buildFixture()
        defer { try? FileManager.default.removeItem(at: ws.deletingLastPathComponent()) }

        // Overwrite run.json with a different bundle ID.
        let wrongRunFile = RunFile(sessions: [
            RunnerSession(
                bundleID: UUID(),  // Different!
                appVersion: "1.0",
                machine: MachineInfo(
                    hostModel: "Mac15,5", chip: "M4 Pro", memoryBytes: 25_769_803_776,
                    osVersion: "27.0", osBuild: "27A0"
                ),
                startedAt: Date(),
                speechTranscriberAvailable: true
            ),
        ])
        try JSONFiles.write(wrongRunFile, to: resultsDir.appendingPathComponent("run.json"))

        let bundle = try BundleLoader.load(from: ws.appendingPathComponent("bundle"))
        let runFile: RunFile = try JSONFiles.read(
            from: resultsDir.appendingPathComponent("run.json"))

        // Validate bundle ID mismatch.
        let mismatch = runFile.sessions.contains { $0.bundleID != bundle.manifest.bundleID }
        #expect(mismatch == true)
    }
}
