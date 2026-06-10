import AVFoundation
import Foundation

/// Seam over AVAudioPlayer so the VM is testable without real audio.
public protocol AudioPlaybackProviding: AnyObject {
    var isPlaying: Bool { get }
    var currentTime: TimeInterval { get set }
    var duration: TimeInterval { get }
    func play()
    func pause()
    func load(url: URL) throws
}

/// Production wrapper around `AVAudioPlayer`.
public final class AVAudioPlayerWrapper: AudioPlaybackProviding {
    private var player: AVAudioPlayer?

    public init() {}

    public var isPlaying: Bool {
        player?.isPlaying ?? false
    }

    public var currentTime: TimeInterval {
        get { player?.currentTime ?? 0 }
        set { player?.currentTime = newValue }
    }

    public var duration: TimeInterval {
        player?.duration ?? 0
    }

    public func play() {
        player?.play()
    }

    public func pause() {
        player?.pause()
    }

    public func load(url: URL) throws {
        player = try AVAudioPlayer(contentsOf: url)
        player?.prepareToPlay()
    }
}
