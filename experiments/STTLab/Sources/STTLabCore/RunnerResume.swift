/// Decision logic for whether to run a meeting in the runner app.
/// Pure function, tested in STTLabCoreTests.
public enum RunnerResume {
    /// Returns true when the meeting should be (re-)transcribed.
    /// - Parameters:
    ///   - existing: A previously saved result for this meeting, if any.
    ///   - force: The user requested a forced re-run.
    public static func shouldRun(existing: AppleMeetingResult?, force: Bool) -> Bool {
        guard let existing else { return true }
        if force { return true }
        switch existing.status {
        case .completed, .unsupportedLocale:
            return false
        case .failed:
            return true
        }
    }
}
