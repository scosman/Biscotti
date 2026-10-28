import Foundation
import LiveTranscription
import LiveTranscriptModel
import Testing
@testable import LiveTranscriptionService

@Suite("LiveTranscriptionDefaults")
struct LiveTranscriptionDefaultsTests {
    @Test("The defaults are the settings the experiment chose")
    func defaultsAreTheMeasuredChoice() {
        #expect(LiveTranscriptionDefaults.engine == .whisper)
        #expect(LiveTranscriptionDefaults.whisperModel == "openai_whisper-small")
        #expect(LiveTranscriptionDefaults.tracks == [.mic, .system])
        #expect(LiveTranscriptionDefaults.updateInterval == 1)
        #expect(WhisperKitLiveDecoder.defaultPrompt == .none, "live Whisper decodes unprompted")
    }

    @Test("A session config carries the defaults and the caller's language and vocabulary")
    func sessionConfigUsesTheDefaults() {
        let id = UUID()
        let config = LiveTranscriptionDefaults.sessionConfig(sessionID: id, generation: 2, language: .english, vocabulary: ["Biscotti"])
        #expect(config == LiveSessionConfig(
            sessionID: id,
            generation: 2,
            engine: .whisper,
            whisperModel: "openai_whisper-small",
            tracks: [.mic, .system],
            updateInterval: 1,
            language: .english,
            vocabulary: ["Biscotti"]
        ))
    }
}
