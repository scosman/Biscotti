import AudioToolbox
@preconcurrency import AVFoundation
import Foundation
import os

private let logger = Logger(subsystem: "net.scosman.biscotti.audiocapture", category: "LiveMicCapture")

/// Encapsulates `ExtAudioFile` creation for the VPIO mic engine.
enum VPIOFileHelper {
    static func createExtAudioFile(
        url: URL,
        encoder: EncoderSettings,
        processingFormat: AVAudioFormat
    ) throws -> ExtAudioFileRef {
        var outputASBD = encoder.outputASBD()
        var fileRef: ExtAudioFileRef?
        let createStatus = ExtAudioFileCreateWithURL(
            url as CFURL, encoder.fileType, &outputASBD, nil,
            AudioFileFlags.eraseFile.rawValue, &fileRef
        )
        guard createStatus == noErr, let file = fileRef else {
            throw CaptureError.micEngineFailed(
                "Failed to create ADTS AAC file (OSStatus \(createStatus))"
            )
        }
        var clientASBD = processingFormat.streamDescription.pointee
        let clientStatus = ExtAudioFileSetProperty(
            file, kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &clientASBD
        )
        guard clientStatus == noErr else {
            ExtAudioFileDispose(file)
            throw CaptureError.micEngineFailed(
                "Failed to set client format (OSStatus \(clientStatus))"
            )
        }
        let brStatus = EncoderSettings.applyBitRate(
            to: file, bitRate: encoder.bitRate
        )
        if brStatus != noErr {
            logger.warning(
                "applyBitRate returned \(brStatus) — using encoder default"
            )
        }
        return file
    }
}
