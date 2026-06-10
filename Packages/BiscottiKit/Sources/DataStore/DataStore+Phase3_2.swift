import Foundation
import SwiftData
import Transcription

// Phase 3.2 extensions: transcripts, audio refs, calendar snapshots,
// association, and search.

// MARK: - Transcripts

public extension DataStore {
    /// Maps a `TranscriptResult` DTO into `TranscriptRecord` / `TranscriptSegmentRecord` /
    /// `TranscriptWordRecord` rows and appends to the meeting's transcripts.
    /// Returns the new `TranscriptRecord`'s ID.
    @discardableResult
    func addTranscript(
        _ result: TranscriptResult,
        vocabularyUsed: [String],
        mappedEventIdentifier: String?,
        to meetingID: UUID
    ) throws -> UUID {
        guard let meeting = try meeting(id: meetingID) else {
            throw DataStoreError.notFound(meetingID)
        }

        let record = TranscriptRecord(
            id: result.id,
            createdAt: result.createdAt,
            transcriptionMethodId: result.transcriptionMethodId,
            vocabularyUsed: vocabularyUsed,
            mappedEventIdentifier: mappedEventIdentifier,
            language: result.language,
            speakerCount: result.speakerCount
        )
        context.insert(record)

        // Map segments with index for stable ordering
        for (segIndex, segment) in result.segments.enumerated() {
            let segRecord = TranscriptSegmentRecord(
                id: segment.id,
                index: segIndex,
                speakerID: segment.speakerID,
                speakerLabel: segment.speakerLabel,
                startTime: segment.startTime,
                endTime: segment.endTime,
                text: segment.text,
                noSpeechProbability: segment.noSpeechProbability
            )
            context.insert(segRecord)

            // Map words with index for stable ordering
            if let words = segment.words {
                for (wordIndex, word) in words.enumerated() {
                    let wordRecord = TranscriptWordRecord(
                        index: wordIndex,
                        word: word.word,
                        startTime: word.startTime,
                        endTime: word.endTime,
                        probability: word.probability,
                        speakerID: word.speakerID
                    )
                    context.insert(wordRecord)
                    segRecord.words.append(wordRecord)
                }
            }

            record.segments.append(segRecord)
        }

        meeting.transcripts.append(record)
        try save()
        return record.id
    }

    /// Sets the preferred (current) transcript version for a meeting.
    /// Throws `notFound` if no transcript with that ID belongs to the meeting.
    func setPreferredTranscript(_ transcriptID: UUID, for meetingID: UUID) throws {
        guard let meeting = try meeting(id: meetingID) else {
            throw DataStoreError.notFound(meetingID)
        }
        guard meeting.transcripts.contains(where: { $0.id == transcriptID }) else {
            throw DataStoreError.notFound(transcriptID)
        }
        meeting.preferredTranscriptID = transcriptID
        try save()
    }

    /// Returns true if the meeting's preferred transcript was produced with different
    /// inputs than supplied now (method/vocab/mapping changed), signaling a re-transcribe.
    /// Returns false if there is no preferred transcript (nothing to be stale).
    func preferredTranscriptIsStale(
        meetingID: UUID,
        currentMethodId: String,
        currentVocabulary: [String],
        currentEventIdentifier: String?
    ) throws -> Bool {
        guard let meeting = try meeting(id: meetingID) else {
            throw DataStoreError.notFound(meetingID)
        }
        guard let preferredID = meeting.preferredTranscriptID else {
            return false
        }
        guard let transcript = meeting.transcripts.first(where: { $0.id == preferredID }) else {
            return false
        }

        if transcript.transcriptionMethodId != currentMethodId { return true }
        if transcript.vocabularyUsed != currentVocabulary { return true }
        if transcript.mappedEventIdentifier != currentEventIdentifier { return true }
        return false
    }
}

// MARK: - Audio Refs

public extension DataStore {
    /// Appends the given audio file references to the meeting.
    func attachAudio(_ refs: [AudioFileRef], to meetingID: UUID) throws {
        guard let meeting = try meeting(id: meetingID) else {
            throw DataStoreError.notFound(meetingID)
        }
        for ref in refs {
            context.insert(ref)
            meeting.audioFiles.append(ref)
        }
        try save()
    }

    /// Refreshes `isPresent` and `byteSize` for every audio file reference on the meeting
    /// by stat-ing each path (resolving bookmarks when the path is missing).
    ///
    /// Note: security-scoped bookmark access (startAccessingSecurityScopedResource)
    /// is a runtime concern handled at the app layer, validated in Phase 4.5.
    func markAudioPresence(meetingID: UUID) throws {
        guard let meeting = try meeting(id: meetingID) else {
            throw DataStoreError.notFound(meetingID)
        }
        let fileManager = FileManager.default
        for ref in meeting.audioFiles {
            if let resolved = resolvedPath(for: ref, fileManager: fileManager) {
                ref.isPresent = true
                if let attrs = try? fileManager.attributesOfItem(atPath: resolved),
                   let size = attrs[.size] as? Int64
                {
                    ref.byteSize = size
                }
            } else {
                ref.isPresent = false
                ref.byteSize = 0
            }
        }
        try save()
    }

    /// Attempts to find a valid file path for the ref: first by direct path,
    /// then by resolving the security-scoped bookmark if present.
    private func resolvedPath(
        for ref: AudioFileRef,
        fileManager: FileManager
    ) -> String? {
        if fileManager.fileExists(atPath: ref.path) {
            return ref.path
        }
        // Fall back to bookmark resolution
        if let bookmark = ref.bookmark {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ), fileManager.fileExists(atPath: url.path) {
                return url.path
            }
        }
        return nil
    }
}

// MARK: - Calendar Snapshot

public extension DataStore {
    /// Sets (replaces) the calendar snapshot for a meeting.
    /// Deletes any pre-existing snapshot entity to avoid orphans.
    func setSnapshot(_ snapshot: CalendarSnapshot, for meetingID: UUID) throws {
        guard let meeting = try meeting(id: meetingID) else {
            throw DataStoreError.notFound(meetingID)
        }
        if let existing = meeting.calendarSnapshot {
            context.delete(existing)
        }
        context.insert(snapshot)
        meeting.calendarSnapshot = snapshot
        try save()
    }

    /// Removes the calendar snapshot from a meeting.
    func clearSnapshot(for meetingID: UUID) throws {
        guard let meeting = try meeting(id: meetingID) else {
            throw DataStoreError.notFound(meetingID)
        }
        if let existing = meeting.calendarSnapshot {
            meeting.calendarSnapshot = nil
            context.delete(existing)
        }
        try save()
    }
}

// MARK: - Association

public extension DataStore {
    /// Associates a meeting with a calendar event. Throws `associationConflict` if the
    /// meeting already has a snapshot with a different `eventIdentifier`.
    func associate(
        meetingID: UUID,
        withEventIdentifier eventIdentifier: String,
        compositeKey: String
    ) throws {
        guard let meeting = try meeting(id: meetingID) else {
            throw DataStoreError.notFound(meetingID)
        }
        if let snapshot = meeting.calendarSnapshot {
            // If already associated with a different event, conflict
            if let existing = snapshot.eventIdentifier, existing != eventIdentifier {
                throw DataStoreError.associationConflict
            }
            snapshot.eventIdentifier = eventIdentifier
            snapshot.compositeKey = compositeKey
        } else {
            // Create a minimal snapshot seeded with meeting.title as a placeholder
            let snapshot = CalendarSnapshot(
                eventIdentifier: eventIdentifier,
                compositeKey: compositeKey,
                title: meeting.title
            )
            context.insert(snapshot)
            meeting.calendarSnapshot = snapshot
        }
        try save()
    }

    /// Unconditionally replaces the event association, regardless of current state.
    func correctAssociation(
        meetingID: UUID,
        toEventIdentifier eventIdentifier: String,
        compositeKey: String
    ) throws {
        guard let meeting = try meeting(id: meetingID) else {
            throw DataStoreError.notFound(meetingID)
        }
        if let snapshot = meeting.calendarSnapshot {
            snapshot.eventIdentifier = eventIdentifier
            snapshot.compositeKey = compositeKey
        } else {
            let snapshot = CalendarSnapshot(
                eventIdentifier: eventIdentifier,
                compositeKey: compositeKey,
                title: meeting.title
            )
            context.insert(snapshot)
            meeting.calendarSnapshot = snapshot
        }
        try save()
    }
}

// MARK: - Test Helpers

public extension DataStore {
    /// Fetches all `CalendarSnapshot` rows in the store (for verification in tests).
    func fetchAllSnapshots() throws -> [CalendarSnapshot] {
        try context.fetch(FetchDescriptor<CalendarSnapshot>())
    }

    /// Fetches all `TranscriptRecord` rows in the store (for verification in tests).
    func fetchAllTranscripts() throws -> [TranscriptRecord] {
        try context.fetch(FetchDescriptor<TranscriptRecord>())
    }

    /// Fetches all `TranscriptSegmentRecord` rows in the store (for verification in tests).
    func fetchAllSegments() throws -> [TranscriptSegmentRecord] {
        try context.fetch(FetchDescriptor<TranscriptSegmentRecord>())
    }

    /// Fetches all `TranscriptWordRecord` rows in the store (for verification in tests).
    func fetchAllWords() throws -> [TranscriptWordRecord] {
        try context.fetch(FetchDescriptor<TranscriptWordRecord>())
    }

    /// Fetches all `AudioFileRef` rows in the store (for verification in tests).
    func fetchAllAudioRefs() throws -> [AudioFileRef] {
        try context.fetch(FetchDescriptor<AudioFileRef>())
    }

    /// Fetches all `Person` rows in the store (for verification in tests).
    func fetchAllPersons() throws -> [Person] {
        try context.fetch(FetchDescriptor<Person>())
    }

    /// Fetches all `AppSettings` rows in the store (for verification in tests).
    func fetchAllSettings() throws -> [AppSettings] {
        try context.fetch(FetchDescriptor<AppSettings>())
    }

    /// Inserts an `AppSettings` instance into the store.
    func insertSettings(_ settings: AppSettings) throws {
        context.insert(settings)
        try save()
    }
}

// MARK: - Search

public extension DataStore {
    /// Case-insensitive search across meeting titles and participant names.
    /// Transcript-text search is deferred to Project 7.
    func search(_ query: String) throws -> [Meeting] {
        let lowered = query.lowercased()

        // Full-table scan + in-memory filter: case-insensitive search across
        // title + participant names isn't expressible in SwiftData #Predicate
        // with relationships. Acceptable at V1 scale.
        let descriptor = FetchDescriptor<Meeting>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let all = try context.fetch(descriptor)
        return all.filter { meeting in
            if meeting.title.lowercased().contains(lowered) {
                return true
            }
            return meeting.participants.contains { person in
                person.name.lowercased().contains(lowered)
            }
        }
    }
}
