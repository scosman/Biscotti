import ArgumentParser
import Foundation
import STTLabCore
import STTLabHome

struct SelectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "select",
        abstract: "Select meetings from the Biscotti store for the experiment"
    )

    @OptionGroup var workspaceOpt: WorkspaceOption

    @Option(name: .long, help: "Biscotti store root directory")
    var storeRoot: String = defaultStoreRoot

    @Option(name: .long, help: "Number of short meetings (25–40 min)")
    var short: Int = 5

    @Option(name: .long, help: "Number of long meetings (50–75 min)")
    var long: Int = 5

    @Flag(name: .long, help: "Overwrite an existing confirmed selection")
    var force: Bool = false

    func run() async throws {
        let ws = workspaceOpt.workspaceURL
        let log = workspaceOpt.openLog(command: "select")

        // Check for existing confirmed selection.
        let selectionURL = ws.appendingPathComponent("selection.json")
        if !force, FileManager.default.fileExists(atPath: selectionURL.path) {
            let existing: SelectionFile = try JSONFiles.read(from: selectionURL)
            if existing.confirmed {
                log.log("ERROR: selection.json is already confirmed. Use --force to overwrite.")
                throw ExitCode.failure
            }
        }

        // Read the store.
        let storeRootURL = URL(fileURLWithPath: (storeRoot as NSString).expandingTildeInPath)
        let scratch = ws.appendingPathComponent("home/store_snapshot")
        let (eligible, rejected) = try await StoreReader.loadCandidates(
            storeRoot: storeRootURL, scratch: scratch, log: log
        )

        if !rejected.isEmpty {
            log.log("Rejected \(rejected.count) meetings:")
            for r in rejected.prefix(20) {
                log.log("  \(r.title): \(r.reason)")
            }
        }

        // Propose selection.
        let selection = Selector.propose(eligible, short: short, long: long)

        // Save audio paths for BundleBuilder.
        // The SelectionEntry does not store audio file paths (they're not meaningful
        // on the runner Mac), so we persist a side-car mapping.
        let audioPathsDir = ws.appendingPathComponent("home/audio_paths")
        try FileManager.default.createDirectory(at: audioPathsDir, withIntermediateDirectories: true)
        for entry in selection.meetings {
            if let candidate = eligible.first(where: { $0.meetingUUID == entry.meetingUUID }) {
                let info = SourceInfo(
                    meetingUUID: candidate.meetingUUID,
                    title: candidate.title,
                    date: candidate.date,
                    micPath: candidate.micPath,
                    systemPath: candidate.systemPath
                )
                let infoURL = audioPathsDir
                    .appendingPathComponent("\(candidate.meetingUUID.uuidString).json")
                try JSONFiles.write(info, to: infoURL)
            }
        }
        // Also save for alternates in case the user swaps them in.
        for entry in selection.alternates {
            if let candidate = eligible.first(where: { $0.meetingUUID == entry.meetingUUID }) {
                let info = SourceInfo(
                    meetingUUID: candidate.meetingUUID,
                    title: candidate.title,
                    date: candidate.date,
                    micPath: candidate.micPath,
                    systemPath: candidate.systemPath
                )
                let infoURL = audioPathsDir
                    .appendingPathComponent("\(candidate.meetingUUID.uuidString).json")
                try JSONFiles.write(info, to: infoURL)
            }
        }

        // Write selection.
        try JSONFiles.write(selection, to: selectionURL)

        // Print table.
        log.log("")
        log.log("Proposed selection:")
        log.log(String(repeating: "-", count: 90))
        log.log(
            String(format: "%-4s %-12s %5s %4s %5s %5s %-6s %s",
                   "#", "Date", "Min", "Spkr", "Words", "WPM", "Bucket", "Title")
        )
        log.log(String(repeating: "-", count: 90))
        for (i, entry) in selection.meetings.enumerated() {
            let dateStr = formatDate(entry.date)
            let minutes = Int(entry.durationSeconds / 60)
            let bucket = entry.bucket?.rawValue ?? "fill"
            let title = String(entry.title.prefix(30))
            log.log(
                String(format: "%-4d %-12s %5d %4d %5d %5.0f %-6s %s",
                       i + 1, dateStr, minutes, entry.speakerCount,
                       entry.wordCount, entry.wordsPerMinute, bucket, title)
            )
        }
        log.log(String(repeating: "-", count: 90))

        if !selection.notes.isEmpty {
            log.log("")
            for note in selection.notes {
                log.log("NOTE: \(note)")
            }
        }

        log.log("")
        log.log("Edit selection.json (remove entries, move entries from alternates, set appleLocale),")
        log.log("then run `sttlab confirm --workspace \(ws.path)`.")
    }

    private func formatDate(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.string(from: date)
    }

    private static var defaultStoreRoot: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/Biscotti"
    }
}
