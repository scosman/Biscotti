import Foundation
import Testing
@testable import Automation

private let utc = TimeZone(identifier: "UTC") ?? .current

private func sampleMeeting(id: UUID = UUID(), title: String = "Weekly sync: Q4 / planning") -> ExportableMeeting {
    ExportableMeeting(
        id: id,
        title: title,
        date: Date(timeIntervalSince1970: 1_763_371_800), // 2025-11-17 09:30 UTC
        durationMinutes: 32,
        attendees: ["Sam Carter", " ", "Priya \"P\" Shah"],
        tags: ["clients"],
        summary: "We agreed to ship Friday.",
        notes: "",
        transcript: "[0:00] Sam\nLet's start.\n\n[0:05] Priya\nReady."
    )
}

private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("automation-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("MeetingMarkdown")
struct MeetingMarkdownTests {
    @Test("renders frontmatter, title and non-empty sections only")
    func render() {
        let meeting = sampleMeeting(id: UUID(uuidString: "1A2B3C4D-0000-0000-0000-000000000000") ?? UUID())
        let text = MeetingMarkdown.render(meeting, timeZone: utc)
        let expected = """
        ---
        biscotti_id: 1A2B3C4D-0000-0000-0000-000000000000
        title: "Weekly sync: Q4 / planning"
        date: 2025-11-17T09:30:00Z
        duration_minutes: 32
        attendees: ["Sam Carter", "Priya \\"P\\" Shah"]
        tags: ["clients"]
        ---

        # Weekly sync: Q4 / planning

        ## Summary

        We agreed to ship Friday.

        ## Transcript

        [0:00] Sam
        Let's start.

        [0:05] Priya
        Ready.

        """
        #expect(text == expected)
        #expect(!text.contains("## Notes"))
    }

    @Test("file name is dated, sanitized and carries the ID marker")
    func fileName() {
        let meeting = sampleMeeting(id: UUID(uuidString: "1A2B3C4D-0000-0000-0000-000000000000") ?? UUID())
        #expect(MeetingMarkdown.fileName(for: meeting, timeZone: utc) == "2025-11-17 0930 Weekly sync Q4 planning [1a2b3c4d].md")
    }

    @Test("sanitize handles empty, dotted and long titles")
    func sanitize() {
        #expect(MeetingMarkdown.sanitize("") == "Untitled Meeting")
        #expect(MeetingMarkdown.sanitize("...hidden") == "hidden")
        #expect(MeetingMarkdown.sanitize("a\nb\tc") == "a b c")
        #expect(MeetingMarkdown.sanitize(String(repeating: "x", count: 300)).count == 100)
    }

    @Test("hasContent")
    func hasContent() {
        #expect(sampleMeeting().hasContent)
        #expect(!ExportableMeeting(id: UUID(), title: "t", date: Date(), summary: " \n").hasContent)
    }
}

@Suite("MeetingExporter -- folder")
struct FolderExportTests {
    @Test("writes the file and replaces an older export after a title change")
    func replacesOnRename() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        let target = ExportTarget(name: "Folder", kind: .folder, path: dir.appendingPathComponent("out").path)
        let exporter = MeetingExporter(git: ProcessGitRunner())

        let first = await exporter.export(sampleMeeting(id: id, title: "Untitled Meeting"), to: [target], timeZone: utc)
        let allSucceeded = first.allSatisfy(\.succeeded)
        #expect(allSucceeded)

        // An unrelated file in the folder must survive.
        let unrelated = dir.appendingPathComponent("out/keep me.md")
        try Data("x".utf8).write(to: unrelated)

        let second = await exporter.export(sampleMeeting(id: id, title: "Budget review"), to: [target], timeZone: utc)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("out").path).sorted()
        #expect(second.first?.succeeded == true)
        #expect(names == ["2025-11-17 0930 Budget review \(MeetingMarkdown.idMarker(for: id)).md", "keep me.md"])
    }

    @Test("one failing target does not stop the others")
    func partialFailure() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let blocker = dir.appendingPathComponent("blocker")
        try Data("file, not a folder".utf8).write(to: blocker)

        let bad = ExportTarget(name: "Bad", kind: .folder, path: blocker.appendingPathComponent("sub").path)
        let good = ExportTarget(name: "Good", kind: .folder, path: dir.appendingPathComponent("good").path)
        let outcomes = await MeetingExporter().export(sampleMeeting(), to: [bad, good], timeZone: utc)
        #expect(outcomes.map(\.succeeded) == [false, true])
        #expect(outcomes[0].error != nil)
    }
}

@Suite("MeetingExporter -- git", .enabled(if: FileManager.default.isExecutableFile(atPath: ProcessGitRunner.locateGit().path)))
struct GitExportTests {
    let git = ProcessGitRunner()

    func makeRepo() async throws -> URL {
        let dir = try makeTempDirectory()
        for args in [
            ["init", "-q", "-b", "main"],
            ["config", "user.email", "test@example.com"],
            ["config", "user.name", "Test"],
            ["commit", "-q", "--allow-empty", "-m", "root"]
        ] {
            let result = try await git.run(args, in: dir)
            #expect(result.exitCode == 0, "\(args): \(result.output)")
        }
        return dir
    }

    func log(_ repo: URL) async throws -> [String] {
        try await git.run(["log", "--format=%s"], in: repo).output
            .split(separator: "\n").map(String.init)
    }

    @Test("commits only the export subfolder and leaves other staged work alone")
    func commitsSubfolderOnly() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        // The user has something staged elsewhere in the repo.
        try Data("wip".utf8).write(to: repo.appendingPathComponent("wip.txt"))
        _ = try await git.run(["add", "wip.txt"], in: repo)

        let id = UUID()
        let target = ExportTarget(name: "Repo", kind: .gitRepository, path: repo.path, subfolder: "meetings")
        let outcomes = await MeetingExporter(git: git).export(sampleMeeting(id: id), to: [target], timeZone: utc)
        #expect(outcomes.first?.succeeded == true, "\(outcomes)")
        #expect(outcomes.first?.pushWarning == nil)

        let messages = try await log(repo)
        #expect(messages.count == 2)
        #expect(messages.first?.hasPrefix("Biscotti: Weekly sync Q4 planning") == true)

        let committed = try await git.run(["show", "--name-only", "--format=", "HEAD"], in: repo).output
        #expect(committed.contains("meetings/"))
        #expect(!committed.contains("wip.txt"))

        let staged = try await git.run(["diff", "--cached", "--name-only"], in: repo).output
        #expect(staged.trimmingCharacters(in: .whitespacesAndNewlines) == "wip.txt")
    }

    @Test("unrelated files in the export folder are never committed")
    func leavesUnrelatedFilesInTheExportFolder() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        // An untracked note sits in the repository root, which is also the
        // export folder.
        try Data("notes".utf8).write(to: repo.appendingPathComponent("notes.txt"))

        let target = ExportTarget(name: "Repo", kind: .gitRepository, path: repo.path, subfolder: "")
        let outcomes = await MeetingExporter(git: git).export(sampleMeeting(id: UUID()), to: [target], timeZone: utc)
        #expect(outcomes.first?.succeeded == true, "\(outcomes)")

        let committed = try await git.run(["show", "--name-only", "--format=", "HEAD"], in: repo).output
        #expect(committed.contains(".md"))
        #expect(!committed.contains("notes.txt"))
        let untracked = try await git.run(["status", "--porcelain"], in: repo).output
        #expect(untracked.contains("?? notes.txt"))
    }

    @Test("re-export with a new title commits the rename; identical re-export commits nothing")
    func renameAndNoop() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let id = UUID()
        let target = ExportTarget(name: "Repo", kind: .gitRepository, path: repo.path, subfolder: "meetings")
        let exporter = MeetingExporter(git: git)

        _ = await exporter.export(sampleMeeting(id: id, title: "Untitled Meeting"), to: [target], timeZone: utc)
        _ = await exporter.export(sampleMeeting(id: id, title: "Budget review"), to: [target], timeZone: utc)
        let again = await exporter.export(sampleMeeting(id: id, title: "Budget review"), to: [target], timeZone: utc)
        #expect(again.first?.succeeded == true)

        #expect(try await log(repo).count == 3)
        let tracked = try await git.run(["ls-files", "meetings"], in: repo).output
            .split(separator: "\n")
        #expect(tracked.count == 1)
        #expect(tracked.first?.contains("Budget review") == true)
    }

    @Test("a failing push is a warning, not a failure")
    func pushFailureIsWarning() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        _ = try await git.run(["remote", "add", "origin", repo.appendingPathComponent("missing-remote").path], in: repo)

        let target = ExportTarget(
            name: "Repo", kind: .gitRepository, path: repo.path, subfolder: "meetings", pushAfterCommit: true
        )
        let outcome = try #require(await MeetingExporter(git: git).export(sampleMeeting(), to: [target], timeZone: utc).first)
        #expect(outcome.succeeded)
        #expect(outcome.pushWarning?.contains("push") == true)
        #expect(try await log(repo).count == 2)
    }

    @Test("a folder that is not a repository fails clearly")
    func notARepository() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = ExportTarget(name: "Repo", kind: .gitRepository, path: dir.path, subfolder: "meetings")
        let outcome = try #require(await MeetingExporter(git: git).export(sampleMeeting(), to: [target], timeZone: utc).first)
        #expect(!outcome.succeeded)
        #expect(outcome.error?.contains("not a git repository") == true)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("meetings").path))
    }
}

@Suite("ProcessGitRunner")
struct GitRunnerTests {
    @Test("missing binary reports gitNotFound")
    func missingBinary() async {
        let runner = ProcessGitRunner(executable: URL(fileURLWithPath: "/nonexistent/git"))
        await #expect(throws: GitRunnerError.gitNotFound) {
            _ = try await runner.run(["status"], in: FileManager.default.temporaryDirectory)
        }
    }

    @Test("a hung command times out")
    func timeout() async throws {
        // A script that ignores its arguments and hangs stands in for git.
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("hang.sh")
        try Data("#!/bin/sh\nexec sleep 10\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let runner = ProcessGitRunner(executable: script, timeout: .milliseconds(300))
        let start = ContinuousClock.now
        await #expect(throws: GitRunnerError.timedOut("status")) {
            _ = try await runner.run(["status"], in: dir)
        }
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test("a timed-out run ends even when a child keeps the output open")
    func timeoutKillsChildren() async throws {
        // Like a git hook that starts a background process: the child holds
        // the output pipe, so reading to end of file would wait for it.
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("hook.sh")
        try Data("#!/bin/sh\nsleep 30 &\nsleep 30\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let runner = ProcessGitRunner(executable: script, timeout: .milliseconds(300))
        let start = ContinuousClock.now
        await #expect(throws: GitRunnerError.timedOut("push")) {
            _ = try await runner.run(["push"], in: dir)
        }
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test("a quick command returns all of its output")
    func collectsOutput() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("echo.sh")
        try Data("#!/bin/sh\nseq 1 20000\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let result = try await ProcessGitRunner(executable: script).run(["status"], in: dir)
        #expect(result.exitCode == 0)
        #expect(result.output.hasSuffix("19999\n20000\n"))
    }
}
