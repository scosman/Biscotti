import DataStore
import Foundation

/// Renders `VoiceprintMetrics` results as human-readable text.
public enum MetricsFormatter {
    /// Renders a single metrics result as a human-readable report.
    public static func text(_ metrics: VoiceprintMetrics, includeSweep: Bool) -> String {
        var lines = formatOneKind(metrics, includeSweep: includeSweep)
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func formatAccuracy(correct: Int, total: Int) -> String {
        total > 0 ? String(format: "%.1f%%", Double(correct) / Double(total) * 100) : "N/A"
    }

    private static func formatOneKind(_ metrics: VoiceprintMetrics, includeSweep: Bool) -> [String] {
        var lines: [String] = []
        lines.append("=== RAW (\(metrics.space)) ===")
        lines.append("")

        let accuracy = formatAccuracy(correct: metrics.top1Correct, total: metrics.trials)
        lines.append("Trials: \(metrics.trials) (\(metrics.trialsWithoutHistory) skipped, no history)")
        lines.append("Top-1 accuracy: \(accuracy) (\(metrics.top1Correct)/\(metrics.trials))")
        lines.append("")

        formatLevels(metrics: metrics, into: &lines)
        formatSweep(metrics: metrics, includeSweep: includeSweep, into: &lines)
        formatCoverage(metrics: metrics, into: &lines)
        formatConfusedPairs(metrics: metrics, into: &lines)
        formatSuspectTags(metrics: metrics, into: &lines)

        return lines
    }

    private static func formatLevels(metrics: VoiceprintMetrics, into lines: inout [String]) {
        lines.append("By level:")
        for level in [MatchLevel.high, .medium, .low, .ambiguous, .none] {
            guard let stats = metrics.byLevel[level] else { continue }
            let pct = formatAccuracy(correct: stats.correct, total: stats.total)
            lines.append("  \(level.rawValue): \(stats.correct)/\(stats.total) (\(pct))")
        }
        lines.append("")

        let eerStr = metrics.equalErrorRadius.map { String(format: "%.2f", $0) } ?? "N/A"
        lines.append("Equal error radius: \(eerStr)")
    }

    private static func formatSweep(
        metrics: VoiceprintMetrics, includeSweep: Bool, into lines: inout [String]
    ) {
        guard includeSweep, !metrics.sweep.isEmpty else { return }
        lines.append("")
        lines.append("Radius sweep:")
        lines.append("  Radius    FMR      MMR")
        for row in metrics.sweep {
            let rStr = String(format: "  %.2f", row.radius)
            let fmr = String(format: "%.4f", row.falseMatchRate)
            let mmr = String(format: "%.4f", row.missedMatchRate)
            lines.append("\(rStr)     \(fmr)   \(mmr)")
        }
    }

    private static func formatCoverage(metrics: VoiceprintMetrics, into lines: inout [String]) {
        lines.append("")
        lines.append("Coverage:")
        lines.append("  People with confirmed tags: \(metrics.coverage.peopleWithConfirmed)")
        lines.append("  With 3+ confirmed meetings: \(metrics.coverage.atLeast3)")
        lines.append("  With 5+ confirmed meetings: \(metrics.coverage.atLeast5)")
        lines.append(
            "  Speech <15s: \(metrics.coverage.speechUnder15s), 15-60s: \(metrics.coverage.speech15to60s), 60-300s: \(metrics.coverage.speech60to300s), >300s: \(metrics.coverage.speechOver300s)"
        )
    }

    private static func formatConfusedPairs(metrics: VoiceprintMetrics, into lines: inout [String]) {
        guard !metrics.confusedPairs.isEmpty else { return }
        lines.append("")
        lines.append("Confused pairs:")
        for pair in metrics.confusedPairs {
            lines.append("  \(pair.truth) -> \(pair.predicted): \(pair.count)")
        }
    }

    private static func formatSuspectTags(metrics: VoiceprintMetrics, into lines: inout [String]) {
        guard !metrics.suspectTags.isEmpty else { return }
        lines.append("")
        lines.append("Suspect tags:")
        let dateFmt = DateFormatter()
        dateFmt.dateStyle = .short
        dateFmt.timeStyle = .none
        for tag in metrics.suspectTags {
            let dateStr = dateFmt.string(from: tag.meetingDate)
            lines.append(
                "  \(tag.person) in \"\(tag.meetingTitle)\" (\(dateStr)) speaker \(tag.speakerID): distance \(String(format: "%.3f", tag.distance))"
            )
        }
    }
}
