#if DEBUG
    import AudioCapture
    import Calendar
    import DataStore
    import Foundation
    import MeetingCatalog
    import MeetingDetection
    import Notifications
    import Permissions
    import Recording
    import Transcription
    import TranscriptionService
    import UserNotifications

    /// Lightweight factory for building an `AppCore` suitable for SwiftUI previews.
    ///
    /// Uses in-memory storage and no-op fakes -- no hardware, no XPC, no CoreML.
    /// All UI modules import this through `AppCore` to drive their preview providers.
    public enum PreviewAppCore {
        /// Creates a preview-ready `AppCore` with an in-memory store.
        @MainActor
        public static func make() throws -> AppCore {
            let store = try DataStore(storage: .inMemory)
            let permissions = Permissions(mic: PreviewMicAuthorizer())
            let storageRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("BiscottiPreview-\(UUID().uuidString)")

            let recording = RecordingController(
                store: store,
                permissions: permissions,
                storageRoot: storageRoot,
                makeRecorder: { PreviewRecorder() }
            )

            let transcription = TranscriptionService(
                store: store,
                engine: PreviewTranscriber()
            )

            let catalog = BundledMeetingCatalog()
            let calendar = CalendarService(
                store: store,
                catalog: catalog,
                provider: PreviewEventStore()
            )

            let detector = MeetingDetector(
                catalog: catalog,
                source: PreviewActivitySource()
            )

            let notifications = NotificationService(
                provider: PreviewNotificationCenter()
            )

            return AppCore(
                store: store,
                permissions: permissions,
                recording: recording,
                transcription: transcription,
                calendar: calendar,
                detector: detector,
                notifications: notifications
            )
        }
    }

    // MARK: - Preview fakes

    private struct PreviewMicAuthorizer: MicAuthorizing {
        func status() -> PermissionState {
            .authorized
        }

        func request() async -> Bool {
            true
        }
    }

    private struct PreviewRecorder: RecorderControlling {
        func requestPermissions(systemProbePath _: URL) async -> Bool {
            true
        }

        func start(paths _: CapturePaths) async throws {}
        func stop() async {}
        func stateStream() -> AsyncStream<CaptureState> {
            AsyncStream { $0.finish() }
        }

        func probableSystemAudioDenied() async -> Bool {
            false
        }

        func observedSystemAudio() async -> Bool {
            false
        }

        func probeSystemAudioWithTone(timeout _: Duration) async -> Bool {
            true
        }
    }

    private struct PreviewTranscriber: Transcribing {
        func ensureModelsDownloaded(status _: (@Sendable (String) -> Void)?) async throws {}
        func processAudio(
            mic _: URL,
            system _: URL,
            customVocabulary _: [String]
        ) async throws -> TranscriptResult {
            TranscriptResult(
                id: UUID(),
                createdAt: Date(),
                transcriptionMethodId: "preview",
                language: "en",
                speakerCount: 0,
                segments: [],
                speakerEmbeddings: [:],
                processingDuration: 0
            )
        }

        func shutdown() async {}
    }

    /// No-op EventStore for previews: authorized, no calendars/events.
    struct PreviewEventStore: EventStoreProviding {
        func authorizationStatus() -> CalendarAuthStatus {
            .authorized
        }

        func requestAccess() async throws -> Bool {
            true
        }

        func calendars() -> [CalendarInfo] {
            []
        }

        func events(in _: DateInterval, calendars _: [String]?) -> [EKEventDTO] {
            []
        }

        func refreshEvent(eventIdentifier _: String, occurrenceStart _: Date) -> EKEventDTO? {
            nil
        }
    }

    /// No-op ActivitySource for previews.
    private struct PreviewActivitySource: ActivitySource {
        func activityStream() -> AsyncStream<[AudioProcess]> {
            AsyncStream { $0.finish() }
        }
    }

    /// No-op NotificationCenter for previews.
    private struct PreviewNotificationCenter: NotificationCenterProviding {
        func requestAuthorization() async throws -> Bool {
            true
        }

        func authorizationStatus() async -> UNAuthorizationStatus {
            .authorized
        }

        func add(_: UNNotificationRequest) async throws {}

        func removePendingRequests(withIdentifiers _: [String]) {}

        func removeDeliveredNotifications(withIdentifiers _: [String]) {}

        func setCategories(_: Set<UNNotificationCategory>) {}
    }
#endif
