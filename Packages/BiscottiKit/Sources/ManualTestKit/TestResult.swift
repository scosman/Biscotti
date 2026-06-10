import Foundation

/// The recorded outcome of a single test step — persisted in the results JSON file.
public struct TestResult: Codable, Sendable, Equatable {
    public let stepID: String
    public var status: TestStatus
    public var note: String?
    public var timestamp: Date?

    public init(stepID: String, status: TestStatus, note: String? = nil, timestamp: Date? = nil) {
        self.stepID = stepID
        self.status = status
        self.note = note
        self.timestamp = timestamp
    }
}
