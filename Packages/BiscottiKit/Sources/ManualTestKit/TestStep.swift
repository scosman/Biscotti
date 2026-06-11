/// A single step in a manual test script.
///
/// Each case represents a different interaction mode:
/// - `.action`: a button the runner taps to execute code (e.g. request permissions).
///   The `run` closure receives a `status` callback it may call to surface a
///   human-readable status message (e.g. download stage) to the UI.
/// - `.instruction`: passive text the human reads and follows.
/// - `.humanQuestion`: a yes/no question the human answers, with an optional note.
/// - `.autoCheck`: an automated assertion the harness runs and displays the result.
public enum TestStep: Sendable, Identifiable {
    case action(
        id: String,
        label: String,
        run: @Sendable (_ status: @escaping @Sendable (String) -> Void) async throws -> Void
    )
    case instruction(id: String, text: String)
    case humanQuestion(id: String, prompt: String)
    case autoCheck(id: String, label: String, check: @Sendable () async -> CheckOutcome)

    public var id: String {
        switch self {
        case let .action(id, _, _): id
        case let .instruction(id, _): id
        case let .humanQuestion(id, _): id
        case let .autoCheck(id, _, _): id
        }
    }

    /// Whether this step yields a recordable pass/fail result.
    ///
    /// `.instruction` steps are passive text the human reads and follows — the
    /// runner offers no control to mark them, so they never produce a
    /// `TestResult`. They are therefore excluded from the results file and the
    /// CI gate (they could only ever appear as `.notRun` and fail it forever).
    /// All other step types are recorded.
    public var isRecordable: Bool {
        switch self {
        case .instruction: false
        case .action, .humanQuestion, .autoCheck: true
        }
    }
}
