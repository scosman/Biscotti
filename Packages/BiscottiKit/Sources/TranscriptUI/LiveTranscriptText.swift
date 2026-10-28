import Foundation
import LiveTranscriptModel

/// The plain text of a live transcript, as Copy puts it on the pasteboard:
/// one line per bubble, prefixed "You:" or "Others:". Mixed-track rows have
/// no prefix, because they name no speaker.
public enum LiveTranscriptText {
    public static func render(_ rows: [LiveRow]) -> String {
        rows.compactMap { row in
            let text = (row.settledText + row.tailText).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return switch row.track {
            case .mic: "\(TranscriptItemBuilder.youName): \(text)"
            case .system: "\(TranscriptItemBuilder.othersName): \(text)"
            case .mixed: text
            }
        }
        .joined(separator: "\n")
    }
}
