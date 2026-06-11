import Foundation

/// Reads and writes the checked-in manual-test results JSON file.
///
/// The file maps step IDs to `TestResult` values. `record` merges new results
/// over existing entries; `markScriptNotRun` resets a script's steps (the
/// staleness convention). The CI gate uses `unrun` to find steps that haven't
/// been marked pass/fail.
public struct ResultsStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    // MARK: - Read / write

    /// Loads the results dictionary from disk. Returns an empty dictionary if the file
    /// does not exist (first run).
    public func load() throws -> [String: TestResult] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return [:]
        }
        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else { return [:] }
        return try JSONDecoder.resultsDecoder.decode([String: TestResult].self, from: data)
    }

    /// Overwrites the results file with the given dictionary.
    public func save(_ results: [String: TestResult]) throws {
        let data = try JSONEncoder.resultsEncoder.encode(results)
        let dir = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Merge / update

    /// Records a single result, merging it into the existing file (overwrites by step ID).
    public func record(_ result: TestResult) throws {
        var results = try load()
        results[result.stepID] = result
        try save(results)
    }

    /// Resets every step in `allStepIDs` to `.notRun` — used by the CLAUDE.md staleness
    /// convention when a library's source changes.
    public func markScriptNotRun(scriptID _: String, allStepIDs: [String]) throws {
        var results = try load()
        for stepID in allStepIDs {
            results[stepID] = TestResult(stepID: stepID, status: .notRun)
        }
        try save(results)
    }

    // MARK: - CI gate helpers

    /// Collects every step ID from the given scripts, including non-recordable
    /// (`.instruction`) steps. Use `recordableStepIDs(in:)` for the results
    /// file / CI gate, which only track steps that produce a pass/fail.
    public func allStepIDs(in scripts: [TestScript]) -> [String] {
        scripts.flatMap { $0.steps.map(\.id) }
    }

    /// Collects the IDs of steps that produce a recordable result — i.e. every
    /// step except `.instruction` (see `TestStep.isRecordable`). This is the
    /// canonical set the results file is expected to cover and the CI gate
    /// enforces; instruction steps are display-only and never recorded.
    public func recordableStepIDs(in scripts: [TestScript]) -> [String] {
        scripts.flatMap { $0.steps.filter(\.isRecordable).map(\.id) }
    }

    /// Returns recordable step IDs that are either missing from the results file
    /// or marked `.notRun`. The CI gate fails when this list is non-empty.
    /// Instruction steps are not recordable, so they are never reported here.
    public func unrun(in scripts: [TestScript]) throws -> [String] {
        let results = try load()
        return recordableStepIDs(in: scripts).filter { id in
            guard let result = results[id] else { return true }
            return result.status == .notRun
        }
    }
}

// MARK: - Coder configuration

private extension JSONEncoder {
    static let resultsEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

private extension JSONDecoder {
    static let resultsDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
