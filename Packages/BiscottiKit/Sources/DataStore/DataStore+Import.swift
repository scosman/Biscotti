import Foundation

public extension DataStore {
    /// Inserts a fully-formed imported meeting in ONE save: the meeting
    /// (caller-supplied id, so the audio directory can be named before
    /// insert), its single present `.system` audio ref, duration and the
    /// placeholder-title flag. Throws on save failure (nothing inserted).
    func createImportedMeeting( // swiftlint:disable:this function_parameter_count
        id: UUID,
        title: String,
        start: Date,
        duration: TimeInterval,
        audioPath: String,
        audioByteSize: Int64
    ) throws {
        let meeting = Meeting(
            id: id,
            title: title,
            startDate: start,
            endDate: start.addingTimeInterval(duration)
        )
        meeting.recordingDuration = duration
        meeting.titleIsPlaceholder = true
        meeting.editedTitle = false
        context.insert(meeting)

        let audioRef = AudioFileRef(
            role: .system,
            path: audioPath,
            byteSize: audioByteSize,
            isPresent: true
        )
        context.insert(audioRef)
        meeting.audioFiles = [audioRef]

        try save()
    }
}
