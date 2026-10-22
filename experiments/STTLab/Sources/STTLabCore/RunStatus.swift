/// Status of a per-meeting engine run.
public enum RunStatus: String, Codable, Sendable {
    case completed
    case failed
    case unsupportedLocale
}
