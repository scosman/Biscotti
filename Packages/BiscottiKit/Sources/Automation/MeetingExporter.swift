import Foundation

/// The result of exporting one meeting to one target.
public struct ExportOutcome: Sendable, Equatable {
    public let targetID: UUID
    public let targetName: String
    public let fileURL: URL?
    /// Nil on success.
    public let error: String?
    /// Set when the file and commit succeeded but `git push` failed. The
    /// export still counts as done; the commit is pushed with the next one.
    public let pushWarning: String?

    public var succeeded: Bool {
        error == nil
    }
}

public enum ExportError: Error, Equatable, LocalizedError {
    case notAGitRepository(String)
    case gitFailed(command: String, output: String)

    public var errorDescription: String? {
        switch self {
        case let .notAGitRepository(path):
            "\(path) is not a git repository."
        case let .gitFailed(command, output):
            "git \(command) failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }
}

/// Writes meeting Markdown to export targets and commits git targets.
public struct MeetingExporter: Sendable {
    private let git: any GitRunning

    public init(git: any GitRunning = ProcessGitRunner()) {
        self.git = git
    }

    /// Exports to each target in turn. A failing target does not stop the others.
    public func export(
        _ meeting: ExportableMeeting,
        to targets: [ExportTarget],
        timeZone: TimeZone = .current
    ) async -> [ExportOutcome] {
        let markdown = MeetingMarkdown.render(meeting, timeZone: timeZone)
        let fileName = MeetingMarkdown.fileName(for: meeting, timeZone: timeZone)
        var outcomes: [ExportOutcome] = []
        for target in targets {
            await outcomes.append(
                export(meeting, markdown: markdown, fileName: fileName, to: target)
            )
        }
        return outcomes
    }

    private func export(
        _ meeting: ExportableMeeting,
        markdown: String,
        fileName: String,
        to target: ExportTarget
    ) async -> ExportOutcome {
        do {
            if target.kind == .gitRepository {
                try await requireRepository(target)
            }
            let written = try writeFileTracked(
                markdown, named: fileName, meetingID: meeting.id, into: target.outputDirectory
            )
            var pushWarning: String?
            if target.kind == .gitRepository {
                pushWarning = try await commit(meeting, to: target, changed: written.changedNames)
            }
            let file = written.file
            return ExportOutcome(
                targetID: target.id, targetName: target.name,
                fileURL: file, error: nil, pushWarning: pushWarning
            )
        } catch {
            return ExportOutcome(
                targetID: target.id, targetName: target.name,
                fileURL: nil, error: error.localizedDescription, pushWarning: nil
            )
        }
    }

    // MARK: - Files

    /// Writes the file atomically, then removes older exports of the same
    /// meeting (matched by the ID marker in the name and the full ID inside)
    /// whose name differs, e.g. after the title changed.
    func writeFile(
        _ markdown: String,
        named fileName: String,
        meetingID: UUID,
        into directory: URL
    ) throws -> URL {
        try writeFileTracked(markdown, named: fileName, meetingID: meetingID, into: directory).file
    }

    /// The file written and the names (in the same folder) it added or removed.
    struct WrittenExport {
        let file: URL
        let changedNames: [String]
    }

    func writeFileTracked(
        _ markdown: String,
        named fileName: String,
        meetingID: UUID,
        into directory: URL
    ) throws -> WrittenExport {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(fileName)
        try Data(markdown.utf8).write(to: destination, options: .atomic)

        var changed = [fileName]
        let siblings = try manager.contentsOfDirectory(atPath: directory.path)
        for name in siblings where name != fileName && MeetingMarkdown.isExport(named: name, in: directory, of: meetingID) {
            try manager.removeItem(at: directory.appendingPathComponent(name))
            changed.append(name)
        }
        return WrittenExport(file: destination, changedNames: changed)
    }

    // MARK: - Git

    private func requireRepository(_ target: ExportTarget) async throws {
        let root = URL(fileURLWithPath: target.path, isDirectory: true)
        let result = try await git.run(["rev-parse", "--is-inside-work-tree"], in: root)
        guard result.exitCode == 0,
              result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        else {
            throw ExportError.notAGitRepository(target.path)
        }
    }

    /// Stages and commits only the files this export wrote or removed, so
    /// anything else in the repository (staged or not, in the export folder
    /// or not) is left alone. Returns a warning when the push fails.
    private func commit(_ meeting: ExportableMeeting, to target: ExportTarget, changed names: [String]) async throws -> String? {
        let root = URL(fileURLWithPath: target.path, isDirectory: true)
        let folder = target.gitPathspec == "." ? "" : target.gitPathspec + "/"
        var paths: [String] = []
        for name in names {
            let path = folder + name
            if FileManager.default.fileExists(atPath: target.outputDirectory.appendingPathComponent(name).path) {
                try await runChecked(["add", "--", path], in: root)
            } else {
                // A removed older export: stage its removal only if git knew it.
                let known = try await git.run(["ls-files", "--", path], in: root)
                guard !known.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                try await runChecked(["rm", "--cached", "--quiet", "--", path], in: root)
            }
            paths.append(path)
        }
        guard !paths.isEmpty else { return nil }
        let diff = try await git.run(["diff", "--cached", "--quiet", "--"] + paths, in: root)
        guard diff.exitCode != 0 else { return nil } // Nothing changed.

        let message = "Biscotti: \(MeetingMarkdown.sanitize(meeting.title)) \(MeetingMarkdown.idMarker(for: meeting.id))"
        try await runChecked(["commit", "--no-verify", "-m", message, "--"] + paths, in: root)

        guard target.pushAfterCommit else { return nil }
        do {
            let push = try await git.run(["push"], in: root)
            guard push.exitCode != 0 else { return nil }
            return ExportError.gitFailed(command: "push", output: push.output).localizedDescription
        } catch {
            return ExportError.gitFailed(command: "push", output: error.localizedDescription).localizedDescription
        }
    }

    private func runChecked(_ arguments: [String], in directory: URL) async throws {
        let result = try await git.run(arguments, in: directory)
        guard result.exitCode == 0 else {
            throw ExportError.gitFailed(command: arguments.first ?? "", output: result.output)
        }
    }
}
