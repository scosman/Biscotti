/// The outcome of an automated check step — pass/fail plus a human-readable detail string.
public struct CheckOutcome: Sendable, Equatable {
    public let passed: Bool
    public let detail: String

    public init(passed: Bool, detail: String) {
        self.passed = passed
        self.detail = detail
    }
}
