import Foundation

/// The models already prepared for the running build, so each is loaded
/// ahead of time once per install, update or rebuild, not on every launch.
///
/// macOS compiles a Core ML model for the Neural Engine the first time a
/// build loads it, which took nearly two minutes for the live model. A new
/// build identity starts with nothing prepared.
@MainActor
public final class PreparedModels {
    static let buildKey = "modelPreparation.build"
    static let modelsKey = "modelPreparation.models"

    public let build: String
    private let defaults: UserDefaults?
    private var models: Set<String>

    /// - Parameter defaults: Keeps the record across launches; nil keeps it in memory.
    public init(build: String, defaults: UserDefaults? = nil) {
        self.build = build
        self.defaults = defaults
        if let defaults, defaults.string(forKey: Self.buildKey) == build {
            models = Set(defaults.stringArray(forKey: Self.modelsKey) ?? [])
        } else {
            models = []
        }
    }

    public func contains(_ model: String) -> Bool {
        models.contains(model)
    }

    func record(_ prepared: [String]) {
        guard !prepared.isEmpty else { return }
        models.formUnion(prepared)
        save()
    }

    func forget(_ model: String) {
        guard models.remove(model) != nil else { return }
        save()
    }

    private func save() {
        defaults?.set(build, forKey: Self.buildKey)
        defaults?.set(models.sorted(), forKey: Self.modelsKey)
    }

    /// Identifies an installed build: its version and build number, when its
    /// executable and each of its XPC services' executables were written, and
    /// the macOS version. A new install, an update, a development rebuild or a
    /// macOS update each give a new identity.
    public nonisolated static func buildIdentity(
        of bundle: Bundle = .main,
        osVersion: String = ProcessInfo.processInfo.operatingSystemVersionString
    ) -> String {
        let info = bundle.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "-"
        let number = info["CFBundleVersion"] as? String ?? "-"
        let services = bundle.bundleURL.appendingPathComponent("Contents/XPCServices", isDirectory: true)
        let serviceBundles = (try? FileManager.default.contentsOfDirectory(at: services, includingPropertiesForKeys: nil)) ?? []
        let executables = [bundle.executableURL] + serviceBundles
            .filter { $0.pathExtension == "xpc" }
            .map { Bundle(url: $0)?.executableURL }
        let stamps = executables.compactMap(\.self).map { url in
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let written = attributes?[.modificationDate] as? Date
            return "\(url.lastPathComponent)@\(Int((written?.timeIntervalSince1970 ?? 0) * 1000))"
        }
        return ([version, number, osVersion] + stamps.sorted()).joined(separator: "|")
    }
}
