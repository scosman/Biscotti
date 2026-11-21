import Foundation
import Synchronization

/// One entry in the microphone priority list.
public enum MicPriorityEntry: Codable, Sendable, Hashable, Identifiable {
    /// A specific device, remembered by its Core Audio UID (stable across reconnects).
    case device(uid: String, name: String)
    /// Any connected headset: Bluetooth (AirPods included), or a USB device
    /// that identifies itself as a headset.
    case anyHeadset
    /// Any connected Bluetooth input.
    case anyBluetooth
    /// Any connected USB audio input (interfaces, docks, USB mics, headsets).
    case anyUSB

    public var id: String {
        switch self {
        case let .device(uid, _): "device:\(uid)"
        case .anyHeadset: "anyHeadset"
        case .anyBluetooth: "anyBluetooth"
        case .anyUSB: "anyUSB"
        }
    }

    /// The "any" entries, in menu order.
    public static let groups: [MicPriorityEntry] = [.anyHeadset, .anyBluetooth, .anyUSB]

    public var title: String {
        switch self {
        case let .device(_, name): name
        case .anyHeadset: "Any headset (AirPods or a USB headset)"
        case .anyBluetooth: "Any Bluetooth device"
        case .anyUSB: "Any USB audio device"
        }
    }
}

/// A connected input device, as the chooser sees it.
public struct MicCandidate: Codable, Sendable, Equatable, Identifiable {
    public enum Connection: String, Codable, Sendable {
        case bluetooth, usb, builtIn, other
    }

    public let uid: String
    public let name: String
    public let isHeadset: Bool
    public let connection: Connection
    /// Whether this is the current macOS default input.
    public let isSystemDefault: Bool

    public var id: String {
        uid
    }

    public init(
        uid: String,
        name: String,
        isHeadset: Bool,
        connection: Connection = .other,
        isSystemDefault: Bool = false
    ) {
        self.uid = uid
        self.name = name
        self.isHeadset = isHeadset
        self.connection = connection
        self.isSystemDefault = isSystemDefault
    }
}

/// Pure priority rules. "System default" is always the implicit last entry.
public enum MicChooser {
    /// Returns the UID to record from, or nil for the system default.
    ///
    /// - Parameters:
    ///   - current: The device in use, during a recording. With
    ///     `allowSwitchUp` off, it is kept while it stays connected, even if
    ///     a higher-priority device appears.
    public static func choose(
        priority: [MicPriorityEntry],
        connected: [MicCandidate],
        current: String? = nil,
        allowSwitchUp: Bool = true
    ) -> String? {
        if !allowSwitchUp, let current, connected.contains(where: { $0.uid == current }) {
            return current
        }
        for entry in priority {
            switch entry {
            case let .device(uid, _):
                if connected.contains(where: { $0.uid == uid }) {
                    return uid
                }
            case .anyHeadset:
                if let pick = firstPreferringDefault(connected.filter(\.isHeadset)) {
                    return pick
                }
            case .anyBluetooth:
                if let pick = firstPreferringDefault(connected.filter { $0.connection == .bluetooth }) {
                    return pick
                }
            case .anyUSB:
                if let pick = firstPreferringDefault(connected.filter { $0.connection == .usb }) {
                    return pick
                }
            }
        }
        return nil
    }

    /// Among matching devices, prefer the one that is already the system
    /// default, so a group entry never fights a choice the user made in macOS.
    private static func firstPreferringDefault(_ matches: [MicCandidate]) -> String? {
        (matches.first(where: \.isSystemDefault) ?? matches.first)?.uid
    }
}

/// Thread-safe snapshot of the microphone policy for the audio engine,
/// which asks for a device from its own queue (never the main actor).
public final class MicPolicyBox: Sendable {
    private struct State {
        var priority: [MicPriorityEntry] = []
        var allowSwitchUp = true
        var current: String?
        var lastChosenName: String?
    }

    private let state = Mutex(State())

    public init() {}

    public func update(priority: [MicPriorityEntry], allowSwitchUp: Bool) {
        state.withLock {
            $0.priority = priority
            $0.allowSwitchUp = allowSwitchUp
        }
    }

    /// Picks a device for the engine and remembers it as current.
    /// Returns nil to use the system default.
    public func choose(connected: [MicCandidate]) -> String? {
        state.withLock { state in
            let uid = MicChooser.choose(
                priority: state.priority, connected: connected,
                current: state.current, allowSwitchUp: state.allowSwitchUp
            )
            let chosen = uid.flatMap { id in connected.first { $0.uid == id } }
                ?? connected.first(where: \.isSystemDefault)
            state.current = chosen?.uid
            state.lastChosenName = chosen?.name
            return uid
        }
    }

    /// Call when a recording ends, so the next one starts from the top of the list.
    public func resetCurrent() {
        state.withLock { $0.current = nil }
    }

    /// Name of the device chosen most recently, for Settings.
    public var lastChosenName: String? {
        state.withLock { $0.lastChosenName }
    }
}
