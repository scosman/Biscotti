import Foundation

/// Product-level policy for each catalog model: RAM requirements, UI copy,
/// and recommendation thresholds. Kept in the app layer (Intelligence), not
/// in `LocalLLM`, so the library stays free of product policy.
public enum ModelPolicy {
    // MARK: - Threshold constants (SI: 1 GB = 1_000_000_000)

    private static let oneGB: UInt64 = 1_000_000_000

    /// Minimum RAM to run the 12B model. Below this, the model is not
    /// runnable and the UI greys it out.
    public static let ramFloor12B: UInt64 = 15 * oneGB

    /// RAM threshold for recommending the 12B model over E2B. At or above
    /// this, 12B is recommended; below, E2B is recommended.
    public static let recommendationRAMThreshold: UInt64 = 24 * oneGB

    // MARK: - Per-model policy

    /// UI marketing description for the model, shown in the Manage Models
    /// sheet. Matches the catalog copy from the functional spec.
    public static func description(id: String) -> String {
        switch id {
        case "gemma-4-12b":
            "Intelligent, but slower and larger. Requires 7 GB of disk and uses 8 GB RAM."
        case "gemma-4-e2b":
            "Small and fast, but not as intelligent. Requires 3 GB of disk and uses 4 GB of RAM."
        default:
            ""
        }
    }

    /// Minimum physical RAM in bytes required to run this model.
    /// Returns 0 for models that run on any supported Mac.
    public static func minRAMBytesToRun(id: String) -> UInt64 {
        switch id {
        case "gemma-4-12b":
            ramFloor12B
        default:
            0
        }
    }

    /// Human-readable approximate RAM usage string for UI copy.
    public static func approxRAMUsageDescription(id: String) -> String {
        switch id {
        case "gemma-4-12b":
            "8 GB"
        case "gemma-4-e2b":
            "4 GB"
        default:
            ""
        }
    }
}
