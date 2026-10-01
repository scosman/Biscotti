import SpeakerKit

/// Shared SpeakerKit configuration builder used by both
/// ``InProcessTranscriptionEngine`` and ``SpeakerAnalyzer``.
enum SpeakerKitConfigFactory {
    /// Build a SpeakerKit (Pyannote) configuration anchored at the shared cache.
    static func make(download: Bool, load: Bool) -> PyannoteConfig {
        PyannoteConfig(
            downloadBase: ModelStorage.downloadBase.path,
            download: download,
            load: load,
            verbose: false
        )
    }
}
