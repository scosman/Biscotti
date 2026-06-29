import AudioCapture
import Calendar
import DataStore
import Foundation
import Intelligence
import MeetingCatalog
import MeetingDetection
import Notifications
import os
import Permissions
import Recording
import Transcription
import TranscriptionService

// MARK: - Production factory

public extension AppCore {
    /// Builds a fully-wired `AppCore` for the real app.
    ///
    /// - Parameters:
    ///   - storageRoot: The app's persistent data directory
    ///     (e.g. `…/Library/Application Support/Biscotti/`). Recordings are
    ///     stored under `Recordings/` within this directory; the DataStore
    ///     file is placed at `<storageRoot>/Biscotti.store`.
    ///   - transcriberServiceName: The Mach service name for the XPC
    ///     transcription worker (e.g. `"net.scosman.biscotti.BiscottiTranscriber"`).
    /// - Returns: A ready-to-use `AppCore`. Call `onLaunch()` after presenting the UI.
    static func live(
        storageRoot: URL,
        transcriberServiceName: String
    ) throws -> AppCore {
        let logger = Logger(
            subsystem: "net.scosman.biscotti",
            category: "startup"
        )

        logger.info("AppCore.live: DataStore init starting")
        let store = try DataStore(storage: .onDisk(storageRoot))
        logger.info("AppCore.live: DataStore init done")

        let permissions = Permissions()
        let recordingsRoot = storageRoot.appendingPathComponent("Recordings")

        logger.info("AppCore.live: RecordingController init")
        let recording = RecordingController(
            store: store,
            permissions: permissions,
            storageRoot: recordingsRoot,
            makeRecorder: {
                LiveRecorderAdapter(recorder: AudioRecorder.live())
            }
        )

        logger.info("AppCore.live: TranscriptionService init")
        let transcriber = Transcriber(backend: .hosted(serviceName: transcriberServiceName))
        let transcription = TranscriptionService(store: store, engine: LiveTranscriberAdapter(transcriber: transcriber))

        logger.info("AppCore.live: CalendarService init")
        let catalog = BundledMeetingCatalog()
        let calendar = CalendarService(store: store, catalog: catalog)

        logger.info("AppCore.live: MeetingDetector init")
        let detector = MeetingDetector(catalog: catalog)

        logger.info("AppCore.live: NotificationService init")
        let notifications = NotificationService()

        // Wire live notification authorizer so requestNotifications() works.
        let notifAuth = LiveNotificationAuthorizerAdapter(
            service: notifications
        )
        permissions.setNotificationAuthorizer(notifAuth)

        logger.info("AppCore.live: ModelManager + Intelligence init")
        let (modelManager, intelligence) = buildModelAndIntelligence(
            store: store
        )

        logger.info("AppCore.live: constructing AppCore")
        let core = AppCore(
            store: store,
            permissions: permissions,
            recording: recording,
            transcription: transcription,
            calendar: calendar,
            detector: detector,
            notifications: notifications,
            intelligence: intelligence,
            modelManager: modelManager
        )
        logger.info("AppCore.live: done")
        return core
    }

    /// Builds the live `ModelManager` + `Intelligence` with real LocalLLM-backed
    /// implementations. Extracted to keep `live(storageRoot:…)` under
    /// the function body length lint limit.
    @MainActor
    private static func buildModelAndIntelligence(
        store: DataStore
    ) -> (ModelManager, Intelligence) {
        let modelProvider = LiveModelProvider()
        let hardwareProbe = LiveHardwareProbe()
        let modelManager = ModelManager(
            store: store,
            models: modelProvider,
            hardware: hardwareProbe
        )
        let llmRunner = LiveLLMRunner()
        let intelligence = Intelligence(
            store: store,
            llm: llmRunner,
            modelManager: modelManager,
            settings: { [store] in
                let saved = try? await store.settings()
                let raw = saved?.summaryPrompt ?? ""
                let effective = raw.isEmpty
                    ? IntelligencePrompts.defaultSummaryPrompt : raw
                return AISettings(
                    enabled: saved?.aiAnalysisEnabled ?? true,
                    summaryPrompt: effective
                )
            }
        )
        return (modelManager, intelligence)
    }
}

// MARK: - AudioRecorder adapter

/// Bridges `AudioCapture.AudioRecorder` to the `RecorderControlling` protocol.
private struct LiveRecorderAdapter: RecorderControlling {
    let recorder: AudioRecorder

    func requestPermissions(systemProbePath: URL) async -> Bool {
        await recorder.requestPermissions(systemProbePath: systemProbePath)
    }

    func start(paths: CapturePaths) async throws {
        try await recorder.start(paths: paths)
    }

    func stop() async {
        await recorder.stop()
    }

    func stateStream() -> AsyncStream<CaptureState> {
        let recorder = recorder
        return AsyncStream { continuation in
            let task = Task {
                let stream = await recorder.stateStream()
                for await state in stream {
                    guard !Task.isCancelled else { break }
                    continuation.yield(state)
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    func probableSystemAudioDenied() async -> Bool {
        await recorder.probableSystemAudioDenied()
    }

    func observedSystemAudio() async -> Bool {
        await recorder.observedSystemAudio()
    }

    func probeSystemAudioWithTone(timeout: Duration) async -> Bool {
        await recorder.probeSystemAudioWithTone(timeout: timeout)
    }
}

// MARK: - Notification authorizer adapter

/// Bridges `NotificationService` to the `NotificationAuthorizing` protocol
/// so that `Permissions.requestNotifications()` actually fires the real
/// `UNUserNotificationCenter.requestAuthorization(options:)` call.
///
/// `@MainActor` because `NotificationService` is `@MainActor`-isolated.
private struct LiveNotificationAuthorizerAdapter: NotificationAuthorizing,
    @unchecked Sendable
{
    let service: NotificationService

    func status() async -> PermissionState {
        let authorized = await service.isCurrentlyAuthorized()
        if authorized {
            return .authorized
        }
        let denied = await service.isDenied()
        return denied ? .denied : .notDetermined
    }

    func request() async -> Bool {
        await service.requestAuthorization()
    }
}

// MARK: - Transcriber adapter

/// Bridges `Transcription.Transcriber` to the `Transcribing` protocol.
private struct LiveTranscriberAdapter: Transcribing {
    let transcriber: Transcriber

    func ensureModelsDownloaded(
        status: (@Sendable (String) -> Void)?
    ) async throws {
        try await transcriber.ensureModelsDownloaded(status: status)
    }

    func processAudio(
        mic: URL,
        system: URL,
        customVocabulary: [String]
    ) async throws -> TranscriptResult {
        try await transcriber.processAudio(
            mic: mic,
            system: system,
            customVocabulary: customVocabulary
        )
    }

    func modelsPresent() async -> Bool {
        await transcriber.modelsPresent()
    }

    func shutdown() async {
        await transcriber.shutdown()
    }

    func cancelModelDownload() async {
        await transcriber.cancelModelDownload()
    }
}
