import Foundation

/// Per-meeting metadata stored alongside the merged WAV in the bundle.
public struct MeetingMeta: Codable, Sendable, Equatable {
    public var meetingID: String
    public var durationSeconds: Double
    public var sampleRate: Double
    public var speakerCount: Int
    public var transcriptLanguage: String
    public var appleLocale: String
    public var audioFile: String
    public var audioSHA256: String

    public init(
        meetingID: String,
        durationSeconds: Double,
        sampleRate: Double = 16000,
        speakerCount: Int,
        transcriptLanguage: String,
        appleLocale: String,
        audioFile: String = "audio.wav",
        audioSHA256: String
    ) {
        self.meetingID = meetingID
        self.durationSeconds = durationSeconds
        self.sampleRate = sampleRate
        self.speakerCount = speakerCount
        self.transcriptLanguage = transcriptLanguage
        self.appleLocale = appleLocale
        self.audioFile = audioFile
        self.audioSHA256 = audioSHA256
    }
}
