import AudioToolbox
import Foundation
@testable import AudioCapture

/// Stands in for the Core Audio process tap in `LiveSystemCaptureEngine`.
/// Creation can be made to fail, the tap's rate can be changed or made
/// unusable, and the engine's ring buffer is kept so a test can enqueue
/// buffers the way the IOProc does.
///
/// Tests drive the engine from one task at a time, so plain properties are
/// enough.
final class FakeTapHardware: @unchecked Sendable {
    /// The tap's sample rate; nil makes the format query fail.
    var rate: Double? = 48000
    /// Number of upcoming tap creations that throw.
    var failNextCreates = 0
    /// Tap creations attempted, including the ones that failed.
    private(set) var createCount = 0
    /// The ring buffer of the last started IOProc.
    private(set) var ring: AudioRingBuffer?

    /// The engine's hardware calls, backed by this fake.
    var operations: LiveSystemCaptureEngine.TapHardware {
        LiveSystemCaptureEngine.TapHardware(
            create: { [self] _ in
                createCount += 1
                if failNextCreates > 0 {
                    failNextCreates -= 1
                    throw CaptureError.tapCreationFailed(-1)
                }
            },
            format: { [self] _ in
                guard let rate else { return nil }
                var format = AudioStreamBasicDescription()
                format.mSampleRate = rate
                format.mFormatID = kAudioFormatLinearPCM
                format.mChannelsPerFrame = 1
                return format
            },
            startIO: { [self] _, ring in
                self.ring = ring
            }
        )
    }
}
