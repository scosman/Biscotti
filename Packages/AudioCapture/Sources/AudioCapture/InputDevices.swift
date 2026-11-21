import CoreAudio
import Foundation

// Input-device enumeration and selection for the mic
// priority setting.

/// A connected audio input device.
public struct InputDeviceInfo: Sendable, Equatable {
    public let id: AudioObjectID
    /// Stable across reconnects; used to remember a device in Settings.
    public let uid: String
    public let name: String
    public let transportType: UInt32
    public let hasOutput: Bool
    public let isSystemDefault: Bool
    /// Terminal type of the first input stream (USB devices report their USB
    /// terminal type here, e.g. 0x0402 for a headset).
    public let inputTerminalType: UInt32

    public var isBluetooth: Bool {
        transportType == kAudioDeviceTransportTypeBluetooth || transportType == kAudioDeviceTransportTypeBluetoothLE
    }

    public var isUSB: Bool {
        transportType == kAudioDeviceTransportTypeUSB
    }

    /// Bluetooth devices (AirPods included), and USB devices that identify
    /// as a headset or handset, or are named like one. Docks and audio
    /// interfaces also record and play, so playing audio alone is not enough.
    public var isHeadset: Bool {
        if isBluetooth {
            return true
        }
        guard isUSB else { return false }
        return Self.usbHeadsetTerminalTypes.contains(inputTerminalType) || Self.looksLikeHeadset(name)
    }

    /// USB Audio Class bi-directional terminal types: handset, headset.
    static let usbHeadsetTerminalTypes: Set<UInt32> = [0x0401, 0x0402]

    static func looksLikeHeadset(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return ["headset", "headphone", "earbud", "earphone", "airpods"].contains { lowered.contains($0) }
    }
}

/// Supplies the device the mic engine should record from.
public protocol MicDeviceSelecting: Sendable {
    /// The UID of the device to use, or nil for the system default input.
    /// Called from the mic engine's queue at every engine (re)build.
    func preferredInputUID(connected: [InputDeviceInfo]) -> String?
}

public enum InputDevices {
    /// Every connected device with at least one input channel, excluding
    /// aggregate devices (Biscotti's own system-audio tap uses one).
    public static func connected() -> [InputDeviceInfo] {
        let defaultID = CoreAudioHelpers.defaultInputDeviceID()
        let ids = CoreAudioHelpers.getPropertyArray(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            address: AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            type: AudioObjectID.self
        )
        return ids.compactMap { id in
            guard (CoreAudioHelpers.channelCount(for: id, scope: kAudioObjectPropertyScopeInput) ?? 0) > 0,
                  let uid = CoreAudioHelpers.deviceUID(for: id)
            else { return nil }
            let transport = CoreAudioHelpers.transportType(for: id) ?? 0
            guard transport != kAudioDeviceTransportTypeAggregate else { return nil }
            return InputDeviceInfo(
                id: id,
                uid: uid,
                name: CoreAudioHelpers.deviceName(for: id) ?? uid,
                transportType: transport,
                hasOutput: (CoreAudioHelpers.channelCount(for: id, scope: kAudioObjectPropertyScopeOutput) ?? 0) > 0,
                isSystemDefault: id == defaultID,
                inputTerminalType: inputTerminalType(of: id)
            )
        }
    }

    private static func inputTerminalType(of deviceID: AudioObjectID) -> UInt32 {
        let streams = CoreAudioHelpers.getPropertyArray(
            objectID: deviceID,
            address: AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            ),
            type: AudioStreamID.self
        )
        guard let first = streams.first else { return 0 }
        return CoreAudioHelpers.getPropertyData(
            objectID: first,
            address: AudioObjectPropertyAddress(
                mSelector: kAudioStreamPropertyTerminalType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            type: UInt32.self
        ) ?? 0
    }

    /// The device to record from: the selector's choice when it is
    /// connected, otherwise the system default.
    static func resolve(using selector: (any MicDeviceSelecting)?) -> InputDeviceInfo? {
        let devices = connected()
        if let selector, let uid = selector.preferredInputUID(connected: devices),
           let match = devices.first(where: { $0.uid == uid })
        {
            return match
        }
        return devices.first(where: \.isSystemDefault)
    }
}

public extension AudioProcess {
    /// A snapshot of every process using audio right now.
    static func current() -> [AudioProcess] {
        CoreAudioHelpers.allAudioProcesses()
    }
}
