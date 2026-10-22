import DataStore
import Foundation
import STTLabCore

/// A meeting candidate extracted from the Biscotti store, ready for selection.
public struct CandidateMeeting: Codable, Sendable, Equatable {
    public var meetingUUID: UUID
    public var title: String
    public var date: Date
    public var durationSeconds: Double
    public var micPath: String
    public var systemPath: String
    public var speakerCount: Int
    public var wordCount: Int
    public var language: String
    public var wordsPerMinute: Double { Double(wordCount) / max(durationSeconds / 60, 1) }

    public init(
        meetingUUID: UUID,
        title: String,
        date: Date,
        durationSeconds: Double,
        micPath: String,
        systemPath: String,
        speakerCount: Int,
        wordCount: Int,
        language: String
    ) {
        self.meetingUUID = meetingUUID
        self.title = title
        self.date = date
        self.durationSeconds = durationSeconds
        self.micPath = micPath
        self.systemPath = systemPath
        self.speakerCount = speakerCount
        self.wordCount = wordCount
        self.language = language
    }
}

/// Rejection reason for a meeting that did not pass eligibility.
public struct RejectedMeeting: Sendable {
    public let title: String
    public let reason: String

    public init(title: String, reason: String) {
        self.title = title
        self.reason = reason
    }
}

/// Reads the Biscotti store to extract eligible meeting candidates.
public enum StoreReader {
    /// The Biscotti app's bundle identifier.
    private static let appBundleID = "net.scosman.biscotti"

    /// Load eligible meeting candidates from the Biscotti store.
    ///
    /// The store is copied to a scratch directory to avoid locking the production
    /// database. The scratch directory is deleted after reading.
    public static func loadCandidates(
        storeRoot: URL,
        scratch: URL,
        log: RunLog
    ) async throws -> (eligible: [CandidateMeeting], rejected: [RejectedMeeting]) {
        // Warn if Biscotti is running (store may be mid-write).
        if isAppRunning(bundleID: appBundleID) {
            log.log("WARNING: Biscotti is running. Quit it for a consistent snapshot.")
        }

        // Copy store files to scratch.
        let fm = FileManager.default
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: scratch)
        }

        let storeFiles = ["Biscotti.store", "Biscotti.store-wal", "Biscotti.store-shm"]
        for name in storeFiles {
            let src = storeRoot.appendingPathComponent(name)
            if fm.fileExists(atPath: src.path) {
                let dst = scratch.appendingPathComponent(name)
                try fm.copyItem(at: src, to: dst)
            }
        }

        log.log("Copied store to scratch: \(scratch.path)")

        // Open the snapshot read-only.
        let store = try DataStore(storage: .onDisk(scratch))

        // Project meetings to Sendable values on the actor.
        let projected: [ProjectedMeeting] = try await store.read { s in
            let meetings = try s.recentMeetings(limit: 100_000)
            return meetings.map { meeting in
                let transcript = resolvePreferredTranscript(meeting: meeting)
                let micRef = meeting.audioFiles.first(where: { $0.role == .mic })
                let sysRef = meeting.audioFiles.first(where: { $0.role == .system })
                let segments = transcript?.segments.sorted(by: { $0.index < $1.index }) ?? []
                let wordCount = segments.reduce(0) { sum, seg in
                    sum + seg.text.split(separator: " ", omittingEmptySubsequences: true).count
                }
                let speakerIDs = Set(segments.compactMap(\.speakerID))
                let duration = meeting.recordingDuration
                    ?? segments.last.map(\.endTime)
                    ?? 0

                return ProjectedMeeting(
                    id: meeting.id,
                    title: meeting.title,
                    date: meeting.startDate ?? meeting.createdAt,
                    durationSeconds: duration,
                    micPath: micRef?.path,
                    micPresent: micRef.map { FileManager.default.isReadableFile(atPath: $0.path) } ?? false,
                    systemPath: sysRef?.path,
                    systemPresent: sysRef.map { FileManager.default.isReadableFile(atPath: $0.path) } ?? false,
                    hasTranscript: transcript != nil,
                    speakerCount: speakerIDs.count,
                    wordCount: wordCount,
                    language: transcript?.language ?? ""
                )
            }
        }

        log.log("Read \(projected.count) meetings from store")

        // Filter for eligibility.
        var eligible: [CandidateMeeting] = []
        var rejected: [RejectedMeeting] = []

        for m in projected {
            if let reason = m.rejectionReason {
                rejected.append(RejectedMeeting(title: m.title, reason: reason))
            } else {
                eligible.append(CandidateMeeting(
                    meetingUUID: m.id,
                    title: m.title,
                    date: m.date,
                    durationSeconds: m.durationSeconds,
                    micPath: m.micPath!,
                    systemPath: m.systemPath!,
                    speakerCount: m.speakerCount,
                    wordCount: m.wordCount,
                    language: m.language
                ))
            }
        }

        log.log("Eligible: \(eligible.count), rejected: \(rejected.count)")
        return (eligible, rejected)
    }

    // MARK: - Private

    private static func isAppRunning(bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Resolve the preferred transcript for a meeting.
    /// Uses preferredTranscriptID if set, else the newest transcript by createdAt.
    private static func resolvePreferredTranscript(
        meeting: Meeting
    ) -> TranscriptRecord? {
        if let prefID = meeting.preferredTranscriptID,
           let match = meeting.transcripts.first(where: { $0.id == prefID })
        {
            return match
        }
        return meeting.transcripts.sorted(by: { $0.createdAt > $1.createdAt }).first
    }
}

// MARK: - Internal projection

/// A Sendable projection of a Meeting used to cross the actor boundary.
private struct ProjectedMeeting: Sendable {
    let id: UUID
    let title: String
    let date: Date
    let durationSeconds: Double
    let micPath: String?
    let micPresent: Bool
    let systemPath: String?
    let systemPresent: Bool
    let hasTranscript: Bool
    let speakerCount: Int
    let wordCount: Int
    let language: String

    var rejectionReason: String? {
        if micPath == nil || !micPresent {
            return "mic recording missing or not readable"
        }
        if systemPath == nil || !systemPresent {
            return "system recording missing or not readable"
        }
        if !hasTranscript {
            return "no transcript"
        }
        if speakerCount < 2 {
            return "fewer than 2 speakers (\(speakerCount))"
        }
        if durationSeconds <= 0 {
            return "zero or negative duration"
        }
        return nil
    }
}

// MARK: - AppKit import for NSRunningApplication

import AppKit
