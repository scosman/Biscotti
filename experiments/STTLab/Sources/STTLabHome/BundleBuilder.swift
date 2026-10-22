import Foundation
import STTLabCore
import Transcription
import WhisperKit

/// Errors from the bundle builder.
public enum BundleBuilderError: Error {
    case audioLoadFailed(meetingID: String, path: String, underlying: any Error)
    case mergeFailed(meetingID: String, underlying: any Error)
}

/// Builds the runner bundle from confirmed meetings.
///
/// For each meeting: copies source AAC to `home/source/<mid>/`, merges mic + system
/// audio with the production `AudioMerger`, writes the merged Float32 WAV, and
/// produces `meta.json`. After all meetings, writes `manifest.json` and `README.txt`.
public enum BundleBuilder {
    /// Build the bundle at the given workspace.
    ///
    /// - Parameters:
    ///   - workspace: The workspace directory URL.
    ///   - force: Rebuild meetings that already have output.
    ///   - log: Logger for status output.
    /// - Returns: The manifest that was written.
    @discardableResult
    public static func build(
        workspace: URL,
        force: Bool = false,
        log: RunLog
    ) async throws -> BundleManifest {
        let selection = try ConsentGate.require(workspace: workspace)

        let bundleDir = workspace.appendingPathComponent("bundle")
        let homeSourceDir = workspace.appendingPathComponent("home/source")
        let fm = FileManager.default

        var completedMIDs: [String] = []
        var errors: [(String, any Error)] = []

        for entry in selection.meetings {
            guard let mid = entry.meetingID else { continue }

            // Skip if already built (unless force).
            let metaURL = bundleDir
                .appendingPathComponent("meetings/\(mid)/meta.json")
            if !force, fm.fileExists(atPath: metaURL.path) {
                log.log("\(mid): already built (skip)")
                completedMIDs.append(mid)
                continue
            }

            log.log("\(mid): building...")

            do {
                // Copy source AAC files to home/source/<mid>/.
                let sourceDir = homeSourceDir.appendingPathComponent(mid)
                try fm.createDirectory(at: sourceDir, withIntermediateDirectories: true)

                // Audio paths live in SourceInfo, not in SelectionEntry (paths are not
                // meaningful on the runner Mac). The SelectCommand writes a side-car
                // at home/audio_paths/<uuid>.json; once built, source.json is canonical.
                let sourceInfoURL = sourceDir.appendingPathComponent("source.json")
                let sourceInfo: SourceInfo
                if fm.fileExists(atPath: sourceInfoURL.path) {
                    sourceInfo = try JSONFiles.read(from: sourceInfoURL)
                } else {
                    // source.json not yet written — read paths from the SelectCommand-provided map.
                    // This happens on the first build. We look for the audio-paths file.
                    let pathsURL = workspace
                        .appendingPathComponent("home/audio_paths/\(entry.meetingUUID.uuidString).json")
                    sourceInfo = try JSONFiles.read(from: pathsURL)
                }

                // Copy AAC files.
                let micDst = sourceDir.appendingPathComponent("mic.aac")
                let sysDst = sourceDir.appendingPathComponent("system.aac")
                try copyIfNeeded(
                    from: URL(fileURLWithPath: sourceInfo.micPath), to: micDst
                )
                try copyIfNeeded(
                    from: URL(fileURLWithPath: sourceInfo.systemPath), to: sysDst
                )

                // Write source.json (metadata about the original meeting).
                if !fm.fileExists(atPath: sourceInfoURL.path) {
                    try JSONFiles.write(sourceInfo, to: sourceInfoURL)
                }

                // Load audio and merge.
                let micSamples: [Float]
                let sysSamples: [Float]
                do {
                    micSamples = try AudioProcessor
                        .loadAudioAsFloatArray(fromPath: sourceInfo.micPath)
                    sysSamples = try AudioProcessor
                        .loadAudioAsFloatArray(fromPath: sourceInfo.systemPath)
                } catch {
                    throw BundleBuilderError.audioLoadFailed(
                        meetingID: mid, path: sourceInfo.micPath, underlying: error
                    )
                }

                let merged: MergeResult
                do {
                    merged = try AudioMerger.merge(mic: micSamples, system: sysSamples)
                } catch {
                    throw BundleBuilderError.mergeFailed(meetingID: mid, underlying: error)
                }

                // Write merged WAV.
                let meetingBundleDir = bundleDir.appendingPathComponent("meetings/\(mid)")
                try fm.createDirectory(at: meetingBundleDir, withIntermediateDirectories: true)
                let wavURL = meetingBundleDir.appendingPathComponent("audio.wav")
                try WAVFile.writeFloat32Mono16k(samples: merged.samples, to: wavURL)

                // Compute SHA-256 of the WAV.
                let sha = try SHA256File.hex(url: wavURL)

                // Write meta.json.
                let meta = MeetingMeta(
                    meetingID: mid,
                    durationSeconds: merged.duration,
                    speakerCount: entry.speakerCount,
                    transcriptLanguage: entry.language,
                    appleLocale: entry.appleLocale,
                    audioSHA256: sha
                )
                try JSONFiles.write(meta, to: metaURL)

                completedMIDs.append(mid)
                let sizeMB = Double(try fm.attributesOfItem(atPath: wavURL.path)[.size] as? Int ?? 0)
                    / 1_048_576
                log.log("\(mid): done (\(String(format: "%.1f", merged.duration))s, "
                    + "\(String(format: "%.0f", sizeMB)) MB)")

            } catch {
                errors.append((mid, error))
                log.log("\(mid): FAILED — \(error)")
            }
        }

        // Write manifest.json (keep existing bundleID if rebuilding).
        let manifestURL = bundleDir.appendingPathComponent("manifest.json")
        let existingManifest: BundleManifest? = fm.fileExists(atPath: manifestURL.path)
            ? try? JSONFiles.read(from: manifestURL)
            : nil

        let manifest = BundleManifest(
            bundleID: existingManifest?.bundleID ?? UUID(),
            meetings: completedMIDs
        )
        try JSONFiles.write(manifest, to: manifestURL)

        // Write README.txt.
        let readmeURL = bundleDir.appendingPathComponent("README.txt")
        try readmeText.write(to: readmeURL, atomically: true, encoding: .utf8)

        // Summary.
        let totalSizeMB = try totalDirectorySize(bundleDir) / 1_048_576
        log.log("Bundle: \(completedMIDs.count) meetings, "
            + "\(String(format: "%.0f", totalSizeMB)) MB total")
        log.log("AirDrop the `bundle` folder to the runner Mac.")

        if !errors.isEmpty {
            log.log("\(errors.count) meeting(s) failed:")
            for (mid, err) in errors {
                log.log("  \(mid): \(err)")
            }
        }

        return manifest
    }

    // MARK: - Private

    private static func copyIfNeeded(from src: URL, to dst: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dst.path) { return }
        let dir = dst.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try fm.copyItem(at: src, to: dst)
    }

    private static func totalDirectorySize(_ url: URL) throws -> Double {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey]
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
            total += Int64(values.fileSize ?? 0)
        }
        return Double(total)
    }

    /// The README.txt written into every bundle.
    static let readmeText = """
    STT Lab — runner instructions (macOS 26 or later)

    1. Copy STTLabRunner.app to this Mac (for example to Applications).
    2. Open it. If macOS says it cannot verify the app: open System Settings →
       Privacy & Security, scroll down, and click "Open Anyway" for STTLabRunner.
       (Or in Terminal: xattr -dr com.apple.quarantine /path/to/STTLabRunner.app)
    3. Click "Choose Bundle…" and select this folder.
    4. Click "Run". Keep the Mac awake and plugged in. It takes about 1–2 hours.
       You can quit and run again; finished meetings are kept.
    5. When done, click "Reveal Results" and AirDrop the results folder back.

    The app makes no network connections except Apple's own speech-model download
    (if the model is not installed yet).
    """
}

// MARK: - SourceInfo

/// Persisted metadata mapping a meeting ID back to the original store meeting.
/// Stored in `home/source/<mid>/source.json`.
public struct SourceInfo: Codable, Sendable, Equatable {
    public var meetingUUID: UUID
    public var title: String
    public var date: Date
    public var micPath: String
    public var systemPath: String

    public init(
        meetingUUID: UUID,
        title: String,
        date: Date,
        micPath: String,
        systemPath: String
    ) {
        self.meetingUUID = meetingUUID
        self.title = title
        self.date = date
        self.micPath = micPath
        self.systemPath = systemPath
    }
}
