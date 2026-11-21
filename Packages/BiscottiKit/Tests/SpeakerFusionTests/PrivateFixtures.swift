import Foundation
import Testing

/// Recordings of real meetings hold real people's names and
/// voices, so they never live in the repository. They sit in
/// ~/Library/Application Support/Biscotti/TestFixtures (or the folder named by
/// BISCOTTI_PRIVATE_FIXTURES), next to a names.json that maps the roles the
/// tests use ("user", "remote1", ...) to the names in that meeting. Tests that
/// need them are skipped on any machine without the folder.
enum PrivateFixtures {
    static var folder: URL {
        if let path = ProcessInfo.processInfo.environment["BISCOTTI_PRIVATE_FIXTURES"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Biscotti/TestFixtures", isDirectory: true)
    }

    static var available: Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent("names.json").path)
    }

    static func has(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path)
    }

    static func url(_ name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try #require(FileManager.default.fileExists(atPath: url.path), "missing private fixture \(name)")
        return url
    }

    private static let names: [String: String] = {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("names.json")) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }()

    /// The real name behind a role, or the role itself when unknown.
    static func name(_ role: String) -> String {
        names[role] ?? role
    }
}
