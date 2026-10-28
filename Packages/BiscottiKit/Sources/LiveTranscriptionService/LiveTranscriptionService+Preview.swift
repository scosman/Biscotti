#if DEBUG
    import Foundation
    import LiveTranscriptModel
    import Transcription

    public extension LiveTranscriptionService {
        /// A service for SwiftUI previews whose engine, once a recording
        /// starts it, shows a short conversation with an unsettled tail.
        static func preview(drawerExpanded: Bool = true) -> LiveTranscriptionService {
            let service = LiveTranscriptionService(
                engine: { PreviewConversationEngine() },
                model: PresentPreviewModel(),
                vocabulary: { _ in [] },
                isEnabled: true,
                defaults: nil,
                macLanguageCode: "en"
            )
            service.isDrawerExpanded = drawerExpanded
            return service
        }
    }

    private struct PresentPreviewModel: LiveModelProviding {
        func isPresent() -> Bool {
            true
        }

        func download(status _: @escaping @Sendable (String) -> Void) async throws {}
    }

    /// Answers a start with the rows of a short call, both tracks.
    private actor PreviewConversationEngine: LiveEngineSession {
        nonisolated let updates: AsyncStream<LiveTrackUpdate>
        private let continuation: AsyncStream<LiveTrackUpdate>.Continuation

        init() {
            (updates, continuation) = AsyncStream.makeStream(of: LiveTrackUpdate.self)
        }

        func start(_ config: LiveSessionConfig) async throws {
            let others = [
                LiveRow(track: .system, startTime: 0, endTime: 4, settledText: "Okay, so the beta build goes out to the first fifty customers on Monday."),
                LiveRow(track: .system, startTime: 7.5, endTime: 11, settledText: "Yes, Priya merged it this morning. QA signed off an hour ago."),
                LiveRow(track: .system, startTime: 15.5, endTime: 19, settledText: "That works, and I'll send", tailText: " the release notes draft tonight so")
            ]
            let mine = [
                LiveRow(track: .mic, startTime: 4.5, endTime: 7, settledText: "Do we have the crash fix from Friday in that build?"),
                LiveRow(track: .mic, startTime: 11.5, endTime: 15, settledText: "Great. Then let's keep the pricing page hidden until the Thursday review.")
            ]
            for (track, rows) in [(LiveTrack.system, others), (LiveTrack.mic, mine)] {
                continuation.yield(LiveTrackUpdate(
                    sessionID: config.sessionID,
                    generation: config.generation,
                    track: track,
                    revision: 1,
                    rows: rows,
                    gaps: [],
                    transcribedThrough: 19,
                    settledThrough: 17
                ))
            }
        }

        func offer(_: LiveAudioChunk) async -> Bool {
            true
        }

        func append(_: LiveAudioChunk) async {}
        func setUpdateInterval(_: TimeInterval) async {}
        func setPaused(_: Bool) async {}
        func finish(timeout _: Duration) async -> [LiveTrackUpdate] {
            continuation.finish()
            return []
        }

        func cancel() async {
            continuation.finish()
        }
    }
#endif
