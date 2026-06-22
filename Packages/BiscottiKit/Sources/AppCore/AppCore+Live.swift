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
        let engine = LiveTranscriberAdapter(transcriber: transcriber)
        let transcription = TranscriptionService(store: store, engine: engine)

        logger.info("AppCore.live: CalendarService init")
        let catalog = BundledMeetingCatalog()
        let calendar = CalendarService(store: store, catalog: catalog)

        logger.info("AppCore.live: MeetingDetector init")
        let detector = MeetingDetector(catalog: catalog)

        logger.info("AppCore.live: NotificationService init")
        let notifications = NotificationService()

        // Wire the live notification authorizer into Permissions so
        // that requestNotifications() actually calls
        // UNUserNotificationCenter.requestAuthorization(options:).
        let notifAuth = LiveNotificationAuthorizerAdapter(
            service: notifications
        )
        permissions.setNotificationAuthorizer(notifAuth)

        logger.info("AppCore.live: Intelligence init")
        let intelligence = buildIntelligence(store: store)

        logger.info("AppCore.live: constructing AppCore")
        let core = AppCore(
            store: store,
            permissions: permissions,
            recording: recording,
            transcription: transcription,
            calendar: calendar,
            detector: detector,
            notifications: notifications,
            intelligence: intelligence
        )
        logger.info("AppCore.live: done")
        return core
    }

    /// Builds the live `Intelligence` service with real LocalLLM-backed
    /// implementations. Extracted to keep `live(storageRoot:…)` under
    /// the function body length lint limit.
    private static func buildIntelligence(
        store: DataStore
    ) -> Intelligence {
        let modelProvider = LiveModelProvider()
        let llmRunner = LiveLLMRunner(modelProvider: modelProvider)
        return Intelligence(
            store: store,
            llm: llmRunner,
            models: modelProvider,
            settings: { [store] in
                let settings = try? await store.settings()
                // Phase 3 interim: map the two old bools into the single
                // `enabled` flag. Phase 4 replaces with `aiAnalysisEnabled`.
                return AISettings(
                    enabled: (settings?.summarizeTranscripts ?? true)
                        || (settings?.guessSpeakerNames ?? true)
                )
            }
        )
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

    func shutdown() async {
        await transcriber.shutdown()
    }
}
