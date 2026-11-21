import CoreAudio
import Testing
@testable import AudioCapture

/// Which devices count as headsets for "Any headset".
@Suite("InputDeviceInfo headset classification")
struct InputDeviceClassificationTests {
    func device(_ name: String, transport: UInt32, hasOutput: Bool = true, terminal: UInt32 = 0) -> InputDeviceInfo {
        InputDeviceInfo(
            id: 1, uid: name, name: name, transportType: transport,
            hasOutput: hasOutput, isSystemDefault: false, inputTerminalType: terminal
        )
    }

    @Test("Bluetooth devices, AirPods included, are headsets")
    func bluetooth() {
        #expect(device("Sam's AirPods Pro", transport: kAudioDeviceTransportTypeBluetooth).isHeadset)
        #expect(device("Some BLE Headset", transport: kAudioDeviceTransportTypeBluetoothLE).isHeadset)
    }

    @Test("a dock or audio interface that records and plays is not a headset")
    func dockIsNotHeadset() {
        let dock = device("OWC Thunderbolt 3 Audio Device", transport: kAudioDeviceTransportTypeUSB)
        #expect(!dock.isHeadset)
        #expect(dock.isUSB)
    }

    @Test("USB headsets are recognized by terminal type or name")
    func usbHeadsets() {
        #expect(device("Jabra Evolve2", transport: kAudioDeviceTransportTypeUSB, terminal: 0x0402).isHeadset)
        #expect(device("Logitech USB Headset", transport: kAudioDeviceTransportTypeUSB).isHeadset)
        #expect(!device("Shure MV7", transport: kAudioDeviceTransportTypeUSB, hasOutput: false).isHeadset)
    }

    @Test("built-in microphones are not headsets")
    func builtIn() {
        #expect(!device("MacBook Pro Microphone", transport: kAudioDeviceTransportTypeBuiltIn).isHeadset)
    }
}
