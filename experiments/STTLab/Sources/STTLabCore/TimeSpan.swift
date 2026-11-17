import Foundation

/// A timed run with wall-clock start and end.
public struct TimedRun: Codable, Sendable, Equatable {
    public var start: Date
    public var end: Date
    public var wallSeconds: Double

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
        wallSeconds = end.timeIntervalSince(start)
    }
}
