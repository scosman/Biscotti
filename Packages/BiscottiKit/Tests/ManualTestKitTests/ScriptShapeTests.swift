import ManualTestKit
import Testing

@Suite("Test-script structural invariants")
struct ScriptShapeTests {
    @Test("Audio Capture script has a non-empty id and title")
    func audioCaptureIdentity() {
        let script = TestScript.audioCapture
        #expect(!script.id.isEmpty)
        #expect(!script.title.isEmpty)
        #expect(script.id == "audio_capture")
    }

    @Test("Transcription script has a non-empty id and title")
    func transcriptionIdentity() {
        let script = TestScript.transcription
        #expect(!script.id.isEmpty)
        #expect(!script.title.isEmpty)
        #expect(script.id == "transcription")
    }

    @Test("Audio Capture script has at least 5 steps")
    func audioCaptureStepCount() {
        #expect(TestScript.audioCapture.steps.count >= 5)
    }

    @Test("Transcription script has at least 5 steps")
    func transcriptionStepCount() {
        #expect(TestScript.transcription.steps.count >= 5)
    }

    @Test("Every step ID in Audio Capture is non-empty")
    func audioCaptureStepIDsNonEmpty() {
        for step in TestScript.audioCapture.steps {
            #expect(!step.id.isEmpty, "Empty step ID in Audio Capture script")
        }
    }

    @Test("Every step ID in Transcription is non-empty")
    func transcriptionStepIDsNonEmpty() {
        for step in TestScript.transcription.steps {
            #expect(!step.id.isEmpty, "Empty step ID in Transcription script")
        }
    }

    @Test("All step IDs across both scripts are unique")
    func allStepIDsUnique() {
        let allSteps = TestScript.audioCapture.steps + TestScript.transcription.steps
        let ids = allSteps.map(\.id)
        let uniqueIDs = Set(ids)
        #expect(ids.count == uniqueIDs.count, "Duplicate step IDs found")
    }

    @Test("allScripts contains both scripts")
    func allScriptsContainsBoth() {
        let ids = allScripts.map(\.id)
        #expect(ids.contains("audio_capture"))
        #expect(ids.contains("transcription"))
        #expect(allScripts.count == 2)
    }

    @Test("Step IDs within Audio Capture are unique")
    func audioCaptureInternalUniqueness() {
        let ids = TestScript.audioCapture.steps.map(\.id)
        #expect(ids.count == Set(ids).count)
    }

    @Test("Step IDs within Transcription are unique")
    func transcriptionInternalUniqueness() {
        let ids = TestScript.transcription.steps.map(\.id)
        #expect(ids.count == Set(ids).count)
    }
}
