import LocalLLM

/// Pure functions that determine whether a model can run on this hardware,
/// which model to recommend, and whether there is enough disk to download.
///
/// All inputs are value types (RAM bytes, disk bytes, catalog entries) --
/// no side effects, fully unit-testable with fabricated values.
public enum ModelSuitability {
    /// Whether `model` is runnable on a Mac with `ram` bytes of physical RAM.
    ///
    /// A model is runnable iff the machine's RAM meets or exceeds the model's
    /// RAM floor. Models with no floor (e.g. E2B) are always runnable.
    public static func canRun(_ model: LLMModel, ram: UInt64) -> Bool {
        ram >= ModelPolicy.minRAMBytesToRun(id: model.id)
    }

    /// The catalog model id recommended for a Mac with `ram` bytes of RAM,
    /// or `nil` if the catalog is empty.
    ///
    /// - If RAM >= 24 GB and the catalog contains the 12B model, recommend 12B.
    /// - Otherwise recommend the smallest always-runnable model (E2B).
    ///
    /// Never returns a non-runnable model id.
    public static func recommendedModelID(
        catalog: [LLMModel], ram: UInt64
    ) -> String? {
        guard !catalog.isEmpty else { return nil }

        if ram >= ModelPolicy.recommendationRAMThreshold {
            // Recommend 12B if it's in the catalog (it's guaranteed runnable
            // at >= 24 GB since its floor is 15 GB).
            if let model12b = catalog.first(where: { $0.id == "gemma-4-12b" }) {
                assert(canRun(model12b, ram: ram))
                return model12b.id
            }
        }

        // Default: the smallest runnable model -- last in catalog order
        // (catalog is sorted largest-first: 12B, E2B). This ensures E2B is
        // recommended for machines below the 24 GB threshold even if 12B is
        // technically runnable (the "middle band" at 15-23 GB).
        return catalog.last { canRun($0, ram: ram) }?.id
    }

    /// Whether there is enough free disk space to download `model`.
    ///
    /// Returns `true` when `freeBytes` is `nil` (unknown capacity) -- never
    /// falsely block a download on a failed capacity read; the downloader's
    /// size validation is the backstop.
    public static func hasEnoughDisk(
        _ model: LLMModel, freeBytes: Int64?
    ) -> Bool {
        guard let freeBytes else { return true }
        return freeBytes >= model.approxDownloadBytes
    }
}
