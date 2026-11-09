import AudioCapture
import AudioToolbox
import AVFoundation
import CoreMedia
import Foundation
import os

private let logger = Logger(
    subsystem: "net.scosman.biscotti", category: "AudioImport"
)

/// Decodes any AVFoundation-readable audio/video source and re-encodes to
/// ADTS AAC-LC mono 24 kHz 64 kbps -- the standard Biscotti recording format.
public struct AVFoundationAudioConverter: AudioConverting {
    private let encoder = EncoderSettings.voice

    public init() {}

    public func convert(
        source: URL, destination: URL
    ) async throws -> ConversionResult {
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw ImportFailure.sourceMissing
        }

        // --- Load asset properties async (before the detached task) ---

        let asset = AVURLAsset(url: source)

        let hasProtected: Bool
        let tracks: [AVAssetTrack]
        do {
            hasProtected = try await asset.load(.hasProtectedContent)
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw ImportFailure.unreadable
        }

        if hasProtected {
            throw ImportFailure.unreadable
        }

        // Pick the first enabled track, or the first track if none is enabled.
        let track: AVAssetTrack
        if let enabled = try await firstEnabled(in: tracks) {
            track = enabled
        } else if let first = tracks.first {
            track = first
        } else {
            throw ImportFailure.noAudio
        }

        let encoder = encoder
        return try await Task.detached(priority: .userInitiated) {
            try Self.convertSync(
                source: source, destination: destination,
                asset: asset, track: track, encoder: encoder
            )
        }.value
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    private static func convertSync(
        source _: URL, destination: URL,
        asset: AVURLAsset, track: AVAssetTrack,
        encoder: EncoderSettings
    ) throws -> ConversionResult {
        var succeeded = false
        var extFile: ExtAudioFileRef?

        defer {
            if let extFile {
                ExtAudioFileDispose(extFile)
            }
            if !succeeded {
                try? FileManager.default.removeItem(at: destination)
            }
        }

        // --- Reader ---

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw ImportFailure.unreadable
        }

        var mono = AudioChannelLayout()
        mono.mChannelLayoutTag = kAudioChannelLayoutTag_Mono
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: encoder.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVChannelLayoutKey: Data(
                bytes: &mono,
                count: MemoryLayout<AudioChannelLayout>.size
            ),
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        let output = AVAssetReaderTrackOutput(
            track: track, outputSettings: outputSettings
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw ImportFailure.unreadable
        }
        reader.add(output)
        guard reader.startReading() else {
            throw ImportFailure.unreadable
        }

        // --- Writer (ExtAudioFile) ---

        let destDir = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: destDir, withIntermediateDirectories: true
        )

        var asbd = encoder.outputASBD()
        let createStatus = ExtAudioFileCreateWithURL(
            destination as CFURL,
            encoder.fileType,
            &asbd,
            nil,
            AudioFileFlags.eraseFile.rawValue,
            &extFile
        )
        guard createStatus == noErr, let openedFile = extFile else {
            throw ImportFailure.saveFailed
        }

        // Set client format (PCM float32 mono 24 kHz).
        guard let clientFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: encoder.sampleRate,
            channels: 1,
            interleaved: true
        ) else {
            throw ImportFailure.saveFailed
        }
        var clientASBD = clientFormat.streamDescription.pointee
        let clientStatus = ExtAudioFileSetProperty(
            openedFile,
            kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
            &clientASBD
        )
        guard clientStatus == noErr else {
            throw ImportFailure.saveFailed
        }

        let brStatus = EncoderSettings.applyBitRate(
            to: openedFile, bitRate: encoder.bitRate
        )
        if brStatus != noErr {
            logger.warning(
                "applyBitRate returned \(brStatus); continuing without explicit bit rate"
            )
        }

        // --- Pump ---

        var totalFrames: Int64 = 0

        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()

            let frames = CMSampleBufferGetNumSamples(sample)
            guard frames > 0 else { continue }

            var abl = AudioBufferList()
            var block: CMBlockBuffer?
            let listStatus =
                CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                    sample,
                    bufferListSizeNeededOut: nil,
                    bufferListOut: &abl,
                    bufferListSize: MemoryLayout<AudioBufferList>.size,
                    blockBufferAllocator: nil,
                    blockBufferMemoryAllocator: nil,
                    flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
                    blockBufferOut: &block
                )
            guard listStatus == noErr else {
                throw ImportFailure.unreadable
            }

            let writeStatus = ExtAudioFileWrite(
                openedFile, UInt32(frames), &abl
            )
            guard writeStatus == noErr else {
                throw ImportFailure.saveFailed
            }
            totalFrames += Int64(frames)
        }

        // --- Finish ---

        if reader.status == .failed {
            throw ImportFailure.unreadable
        }

        // Dispose and nil out so the defer doesn't double-dispose.
        let disposeStatus = ExtAudioFileDispose(openedFile)
        extFile = nil
        guard disposeStatus == noErr else {
            throw ImportFailure.saveFailed
        }

        guard totalFrames > 0 else {
            throw ImportFailure.noAudio
        }

        let attrs = try FileManager.default.attributesOfItem(
            atPath: destination.path
        )
        let byteSize = (attrs[.size] as? Int64) ?? 0

        succeeded = true
        return ConversionResult(
            duration: Double(totalFrames) / encoder.sampleRate,
            byteSize: byteSize
        )
    }

    /// Returns the first enabled track, or nil.
    private func firstEnabled(
        in tracks: [AVAssetTrack]
    ) async throws -> AVAssetTrack? {
        for track in tracks {
            let enabled = await (try? track.load(.isEnabled)) ?? true
            if enabled { return track }
        }
        return nil
    }
}
