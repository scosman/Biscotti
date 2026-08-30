import Foundation
import MCP

// Centralized argument decoding for the tool handlers (architecture §5.2):
// every malformed or out-of-range argument becomes `invalidParams` with a
// message naming the offending field. Lives in its own file so the provider's
// body stays within the repo's strict type-body-length limit.

extension MeetingToolProvider {
    // MARK: - Argument decoding

    func requiredUUID(_ name: String, in arguments: [String: Value]) throws -> UUID {
        guard let value = arguments[name] else {
            throw MCPError.invalidParams("Missing required parameter '\(name)'.")
        }
        guard let string = value.stringValue else {
            throw MCPError.invalidParams("Parameter '\(name)' must be a string.")
        }
        guard let uuid = UUID(uuidString: string) else {
            throw MCPError.invalidParams("Parameter '\(name)' is not a valid UUID.")
        }
        return uuid
    }

    func optionalNonEmptyString(
        _ name: String, in arguments: [String: Value]
    ) throws -> String? {
        guard let value = arguments[name] else { return nil }
        guard let string = value.stringValue else {
            throw MCPError.invalidParams("Parameter '\(name)' must be a string.")
        }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MCPError.invalidParams("Parameter '\(name)' must not be empty.")
        }
        return trimmed
    }

    func optionalDate(
        _ name: String, in arguments: [String: Value]
    ) throws -> Date? {
        guard let string = try optionalNonEmptyString(name, in: arguments) else { return nil }
        guard let date = ToolDateFormatting.parse(string) else {
            throw MCPError.invalidParams(
                "Parameter '\(name)' is not a valid ISO-8601 date (expected e.g. 2026-08-30T14:03:00Z or 2026-08-30)."
            )
        }
        return date
    }

    func optionalInt(
        _ name: String, in arguments: [String: Value], range: ClosedRange<Int>
    ) throws -> Int? {
        guard let value = arguments[name] else { return nil }
        guard let int = value.intValue else {
            throw MCPError.invalidParams("Parameter '\(name)' must be an integer.")
        }
        guard range.contains(int) else {
            throw MCPError.invalidParams(
                "Parameter '\(name)' must be between \(range.lowerBound) and \(range.upperBound)."
            )
        }
        return int
    }
}
