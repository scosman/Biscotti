import AVFoundation
import Foundation

/// Seam over AVAudioPlayer so the VM is testable without real audio.
///
/// Supports loading one or two audio files (mic + system) for synced
/// dual-file playback. All state properties (`isPlaying`, `currentTime`,
/// `duration`) reflect the combined playback state.
public protocol AudioPlaybackProviding: AnyObject {
    var isPlaying: Bool { get }
    var currentTime: TimeInterval { get set }
    var duration: TimeInterval { get }

    func play()
    func pause()

    /// Loads one or more audio files for synced playback.
    /// Replaces any previously loaded files.
    func load(urls: [URL]) throws
}

/// Production wrapper that plays up to two `AVAudioPlayer` instances in
/// lock-step. Uses `play(atTime:)` with a shared `deviceCurrentTime` to
/// start both players sample-aligned. Pause, seek, and stop apply to all
/// loaded players; `duration` is the longer of the two; `currentTime`
/// tracks the primary (first) player.
public final class AVAudioPlayerWrapper: AudioPlaybackProviding {
    private var players: [AVAudioPlayer] = []

    /// Small lead time (50ms) for synced start via `play(atTime:)`.
    private static let syncLeadTime: TimeInterval = 0.05

    public init() {}

    public var isPlaying: Bool {
        players.first?.isPlaying ?? false
    }

    public var currentTime: TimeInterval {
        get { players.first?.currentTime ?? 0 }
        set {
            for player in players {
                player.currentTime = newValue
            }
        }
    }

    public var duration: TimeInterval {
        players.map(\.duration).max() ?? 0
    }

    public func play() {
        guard !players.isEmpty else { return }
        if players.count == 1 {
            players[0].play()
        } else {
            // Synced start: all players begin at the same device-clock
            // instant, ensuring sample-aligned playback.
            let startTime = players[0].deviceCurrentTime
                + Self.syncLeadTime
            for player in players {
                player.play(atTime: startTime)
            }
        }
    }

    public func pause() {
        for player in players {
            player.pause()
        }
    }

    public func load(urls: [URL]) throws {
        var loaded: [AVAudioPlayer] = []
        for url in urls {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            loaded.append(player)
        }
        players = loaded
    }
}
