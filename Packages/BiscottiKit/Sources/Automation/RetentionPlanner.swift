import Foundation

/// How long recordings and meetings are kept. `nil` means keep forever.
public struct RetentionPolicy: Codable, Sendable, Equatable {
    /// Days to keep audio files after the meeting. `0` deletes audio as
    /// soon as the transcript exists. Transcript, summary and notes stay.
    public var audioRetentionDays: Int?
    /// Days to keep whole meetings (audio, transcript, summary, notes).
    public var meetingRetentionDays: Int?
    /// Only delete a whole meeting after it was exported to every enabled
    /// export target. With no targets configured, nothing is deleted.
    public var requireExportBeforeDelete: Bool

    public init(
        audioRetentionDays: Int? = nil,
        meetingRetentionDays: Int? = nil,
        requireExportBeforeDelete: Bool = true
    ) {
        self.audioRetentionDays = audioRetentionDays
        self.meetingRetentionDays = meetingRetentionDays
        self.requireExportBeforeDelete = requireExportBeforeDelete
    }

    /// Picker choices for audio retention.
    public static let audioChoices: [Int?] = [nil, 0, 1, 7, 14, 30, 90]
    /// Picker choices for meeting retention.
    public static let meetingChoices: [Int?] = [nil, 30, 90, 180, 365]

    public static func label(forDays days: Int?) -> String {
        switch days {
        case nil: "Keep forever"
        case 0: "After transcription"
        case 1: "1 day"
        case let .some(value): "\(value) days"
        }
    }
}

/// One meeting as the planner sees it.
public struct RetentionCandidate: Sendable, Equatable {
    public let id: UUID
    public let date: Date
    public let hasTranscript: Bool
    public let hasAudio: Bool
    public let isExported: Bool

    public init(id: UUID, date: Date, hasTranscript: Bool, hasAudio: Bool, isExported: Bool) {
        self.id = id
        self.date = date
        self.hasTranscript = hasTranscript
        self.hasAudio = hasAudio
        self.isExported = isExported
    }
}

/// What one grooming pass will delete.
public struct RetentionPlan: Sendable, Equatable {
    public var audioToDelete: [UUID] = []
    public var meetingsToDelete: [UUID] = []

    public init(audioToDelete: [UUID] = [], meetingsToDelete: [UUID] = []) {
        self.audioToDelete = audioToDelete
        self.meetingsToDelete = meetingsToDelete
    }

    public var isEmpty: Bool {
        audioToDelete.isEmpty && meetingsToDelete.isEmpty
    }
}

/// Pure retention rules.
public enum RetentionPlanner {
    /// - Parameters:
    ///   - protected: Meetings never touched this pass (recording now,
    ///     queued or running in post-processing).
    ///   - hasEnabledExportTargets: Whether any export target is enabled.
    ///     With `requireExportBeforeDelete` on and no targets, no meeting
    ///     is deleted.
    public static func plan(
        candidates: [RetentionCandidate],
        policy: RetentionPolicy,
        now: Date,
        protected: Set<UUID>,
        hasEnabledExportTargets: Bool
    ) -> RetentionPlan {
        var plan = RetentionPlan()
        for candidate in candidates where !protected.contains(candidate.id) {
            if shouldDeleteMeeting(candidate, policy: policy, now: now, hasTargets: hasEnabledExportTargets) {
                plan.meetingsToDelete.append(candidate.id)
            } else if shouldDeleteAudio(candidate, policy: policy, now: now) {
                plan.audioToDelete.append(candidate.id)
            }
        }
        return plan
    }

    private static func shouldDeleteMeeting(
        _ candidate: RetentionCandidate,
        policy: RetentionPolicy,
        now: Date,
        hasTargets: Bool
    ) -> Bool {
        guard let days = policy.meetingRetentionDays,
              isOlder(candidate.date, thanDays: days, now: now)
        else { return false }
        guard policy.requireExportBeforeDelete else { return true }
        return hasTargets && candidate.isExported
    }

    private static func shouldDeleteAudio(
        _ candidate: RetentionCandidate,
        policy: RetentionPolicy,
        now: Date
    ) -> Bool {
        guard let days = policy.audioRetentionDays,
              candidate.hasAudio,
              candidate.hasTranscript
        else { return false }
        return days == 0 || isOlder(candidate.date, thanDays: days, now: now)
    }

    private static func isOlder(_ date: Date, thanDays days: Int, now: Date) -> Bool {
        now.timeIntervalSince(date) >= TimeInterval(days) * 86400
    }
}
