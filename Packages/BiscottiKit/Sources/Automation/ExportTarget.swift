import Foundation

/// A place meeting text is written automatically after processing finishes.
public struct ExportTarget: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// Markdown files written into a folder.
        case folder
        /// Markdown files written into a subfolder of a git working tree,
        /// then committed (and optionally pushed).
        case gitRepository

        public var title: String {
            switch self {
            case .folder: "Folder"
            case .gitRepository: "Git Repository"
            }
        }
    }

    public var id: UUID
    public var name: String
    public var kind: Kind
    /// Absolute path: the folder for `.folder`, the repository root for
    /// `.gitRepository`.
    public var path: String
    /// Path inside the repository that receives the files. Git targets only.
    /// Empty means the repository root.
    public var subfolder: String
    /// Run `git push` after each commit. Git targets only.
    public var pushAfterCommit: Bool
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        kind: Kind,
        path: String,
        subfolder: String = "",
        pushAfterCommit: Bool = false,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.path = path
        self.subfolder = subfolder
        self.pushAfterCommit = pushAfterCommit
        self.isEnabled = isEnabled
    }

    /// Default subfolder for a new git target.
    public static let defaultGitSubfolder = "meetings"

    /// The directory files are written into.
    public var outputDirectory: URL {
        let root = URL(fileURLWithPath: path, isDirectory: true)
        guard kind == .gitRepository else { return root }
        let trimmed = Self.cleanSubfolder(subfolder)
        return trimmed.isEmpty ? root : root.appendingPathComponent(trimmed, isDirectory: true)
    }

    /// The subfolder as a git pathspec relative to the repository root
    /// (`.` for the root itself).
    public var gitPathspec: String {
        let trimmed = Self.cleanSubfolder(subfolder)
        return trimmed.isEmpty ? "." : trimmed
    }

    /// Strips surrounding slashes and whitespace, and refuses any `..`
    /// component so a subfolder can never point outside the repository.
    static func cleanSubfolder(_ raw: String) -> String {
        let parts = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        return parts.joined(separator: "/")
    }
}
