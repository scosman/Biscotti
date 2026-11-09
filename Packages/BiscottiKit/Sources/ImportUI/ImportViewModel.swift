import AppCore
import AppKit
import AudioImport
import DataStore
import Formatting
import Foundation

/// Row model for the Import screen list.
public struct ImportRowModel: Identifiable, Equatable {
    public enum Icon: Equatable, Sendable { case sage, neutral, failed }
    public enum Trailing: Equatable, Sendable {
        case waiting
        case receiving
        case converting
        case goToMeeting(UUID)
        case deleted
        case showInFinder
        case none
    }

    public let id: UUID
    public let name: String
    /// Date text, a single space placeholder, or an error message.
    public let secondLine: String
    public let secondLineIsError: Bool
    public let icon: Icon
    public let trailing: Trailing
}

/// View model for the Import screen. Maps `AudioImportController` state
/// into display-ready header copy and row models.
@MainActor @Observable
public final class ImportViewModel {
    private let core: AppCore
    private let revealInFinder: @MainActor (URL) -> Void
    private let openFolder: @MainActor (URL) -> Void

    public init(
        core: AppCore,
        revealInFinder: @escaping @MainActor (URL) -> Void = liveReveal,
        openFolder: @escaping @MainActor (URL) -> Void = liveOpenFolder
    ) {
        self.core = core
        self.revealInFinder = revealInFinder
        self.openFolder = openFolder
    }

    // MARK: - Derived state

    public var header: ImportHeaderCopy {
        ImportHeaderCopy.make(
            items: core.audioImport.items,
            run: core.audioImport.run,
            runPosition: core.audioImport.runPosition
        )
    }

    public var rows: [ImportRowModel] {
        core.audioImport.items.map { item in
            mapRow(item)
        }
    }

    // MARK: - Actions

    public func goToMeeting(_ meetingID: UUID) {
        core.select(meetingID)
    }

    public func showInFinder(_ rowID: UUID) {
        guard let item = core.audioImport.items.first(where: {
            $0.id == rowID
        }) else { return }
        guard let url = item.sourceURL else { return }

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) {
            revealInFinder(url)
        } else {
            // Walk up until an existing directory is found.
            var dir = url.deletingLastPathComponent()
            while !fileManager.fileExists(atPath: dir.path), dir.path != "/" {
                dir = dir.deletingLastPathComponent()
            }
            openFolder(dir)
        }
    }

    // MARK: - Row mapping

    private func mapRow(_ item: ImportItem) -> ImportRowModel {
        let dateLine = dateText(for: item)

        switch item.status {
        case .receiving, .waiting:
            let trailing: ImportRowModel.Trailing =
                item.status == .waiting ? .waiting : .receiving
            return ImportRowModel(
                id: item.id,
                name: item.displayName,
                secondLine: dateLine,
                secondLineIsError: false,
                icon: .neutral,
                trailing: trailing
            )

        case .converting:
            return ImportRowModel(
                id: item.id,
                name: item.displayName,
                secondLine: dateLine,
                secondLineIsError: false,
                icon: .sage,
                trailing: .converting
            )

        case let .done(meetingID):
            let meetingExists = core.summaries.contains { $0.id == meetingID }
            return ImportRowModel(
                id: item.id,
                name: item.displayName,
                secondLine: dateLine,
                secondLineIsError: false,
                icon: .sage,
                trailing: meetingExists
                    ? .goToMeeting(meetingID) : .deleted
            )

        case let .failed(failure):
            let hasSource = item.sourceURL != nil
            return ImportRowModel(
                id: item.id,
                name: item.displayName,
                secondLine: failure.message,
                secondLineIsError: true,
                icon: .failed,
                trailing: hasSource ? .showInFinder : .none
            )
        }
    }

    private func dateText(for item: ImportItem) -> String {
        guard let date = item.meetingDate else { return " " }
        return TimeFormatting.dateAndTime(date)
    }

    // MARK: - Default reveal

    public static let liveReveal: @MainActor (URL) -> Void = { url in
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    public static let liveOpenFolder: @MainActor (URL) -> Void = { url in
        NSWorkspace.shared.open(url)
    }
}
