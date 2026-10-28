import Foundation

/// What `TranscriberServiceProtocol.prepareModels` asks the worker to load.
public struct ModelPreparationRequest: Codable, Sendable, Equatable {
    /// Whisper model folder names, loaded in order.
    public var models: [String]
    /// One of `models` to keep loaded afterwards, for the live sessions that
    /// follow, instead of unloading it.
    public var keepLoaded: String?
    /// Loads `keepLoaded` again even when it is already loaded, for example
    /// after its files were downloaded again.
    public var reloadsKeptModel: Bool

    public init(models: [String], keepLoaded: String? = nil, reloadsKeptModel: Bool = false) {
        self.models = models
        self.keepLoaded = keepLoaded
        self.reloadsKeptModel = reloadsKeptModel
    }

    private enum CodingKeys: String, CodingKey {
        case models, keepLoaded, reloadsKeptModel
    }

    /// A request without `reloadsKeptModel` does not reload.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        models = try container.decode([String].self, forKey: .models)
        keepLoaded = try container.decodeIfPresent(String.self, forKey: .keepLoaded)
        reloadsKeptModel = try container.decodeIfPresent(Bool.self, forKey: .reloadsKeptModel) ?? false
    }
}
