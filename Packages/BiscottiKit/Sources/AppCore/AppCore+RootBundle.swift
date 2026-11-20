import Foundation
import SpeakerFusion

// MARK: - Root bundle

/// A meeting's root bundle is the evidence its transcript and export are
/// built from: the audio, the meeting-window capture (including live
/// caption text), and in future transcripts from other systems. It lives in
/// the meeting's recordings folder and is deleted with the audio.
enum RootBundle {
    /// Files in a bundle folder that are evidence rather than audio: the
    /// meeting-window capture and the meeting's event log.
    static func isEvidence(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return (name.hasPrefix("ui-capture") && url.pathExtension == "jsonl") || name == MeetingEventLog.fileName
    }

    static func removeEvidence(in folder: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where isEvidence(file) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

extension AppCore {
    /// The meeting's recordings folder, which is its root bundle.
    func rootBundleFolder(meetingID: UUID) -> URL {
        audioImport.recordingsRoot.appendingPathComponent(meetingID.uuidString, isDirectory: true)
    }
}

// MARK: - People that were never people

extension AppCore {
    /// Caption UI, caption lines and audio devices that an earlier build
    /// read as names.
    nonisolated static func isJunkPersonName(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return lowered.contains("caption") || lowered.hasPrefix("doing ok") || PersonName.isNotAPerson(name)
    }

    func removeJunkPeople() async {
        let removed = await (try? store.removeJunkPeople(where: Self.isJunkPersonName)) ?? 0
        if removed > 0 {
            MeetingEventLog.write("people", "Removed \(removed) people that were caption text or devices, not names")
        }
    }
}
