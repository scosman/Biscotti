/// The pass/fail/not-run status of a single test step.
public enum TestStatus: String, Codable, Sendable {
    case pass
    case fail
    case notRun = "not-run"
}
