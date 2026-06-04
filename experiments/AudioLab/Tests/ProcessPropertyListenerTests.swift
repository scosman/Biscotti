import CoreAudio
import XCTest

@testable import AudioLab

final class ProcessPropertyListenerTests: XCTestCase {

    // MARK: - processIOState

    func testProcessIOStateReturnsDefaultsForInvalidID() {
        // An AudioObjectID of 0 is not a valid process object.
        // processIOState should return (false, false) gracefully.
        let state = CoreAudioHelpers.processIOState(for: AudioObjectID(0))
        XCTAssertFalse(state.isRunningInput)
        XCTAssertFalse(state.isRunningOutput)
    }

    func testProcessIOStateReturnsDefaultsForSystemObject() {
        // The system object is not a process, so the process-specific
        // properties should return defaults.
        let state = CoreAudioHelpers.processIOState(
            for: AudioObjectID(kAudioObjectSystemObject)
        )
        XCTAssertFalse(state.isRunningInput)
        XCTAssertFalse(state.isRunningOutput)
    }

    // MARK: - addProcessPropertyListener with invalid ID

    func testAddListenerReturnsNilForInvalidProcessID() {
        let queue = DispatchQueue(label: "test.listener")
        // Use kAudioProcessPropertyIsRunning (the property that actually fires
        // notifications) rather than the IsRunningInput/IsRunningOutput variants
        // which are broken on macOS 15.
        let listener = CoreAudioHelpers.addProcessPropertyListener(
            processID: AudioObjectID(0),
            property: kAudioProcessPropertyIsRunning,
            queue: queue,
            handler: {}
        )
        XCTAssertNil(listener, "Listener should not be created for an invalid process ID")
    }

    // MARK: - ProcessPropertyListener struct

    func testProcessPropertyListenerStoresFields() {
        let queue = DispatchQueue(label: "test.fields")
        let block: AudioObjectPropertyListenerBlock = { _, _ in }
        let listener = CoreAudioHelpers.ProcessPropertyListener(
            objectID: 42,
            propertySelector: kAudioProcessPropertyIsRunningOutput,
            block: block,
            queue: queue
        )
        XCTAssertEqual(listener.objectID, 42)
        XCTAssertEqual(listener.propertySelector, kAudioProcessPropertyIsRunningOutput)
    }

    // MARK: - removeProcessPropertyListener does not crash

    func testRemoveListenerWithInvalidIDDoesNotCrash() {
        // Removing a listener that was never added should not crash.
        let queue = DispatchQueue(label: "test.remove")
        let block: AudioObjectPropertyListenerBlock = { _, _ in }
        let listener = CoreAudioHelpers.ProcessPropertyListener(
            objectID: 0,
            propertySelector: kAudioProcessPropertyIsRunningInput,
            block: block,
            queue: queue
        )
        // This should complete without crashing
        CoreAudioHelpers.removeProcessPropertyListener(listener)
    }
}
