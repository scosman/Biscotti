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

    @Test("Audio Capture script has exactly 16 steps")
    func audioCaptureStepCount() {
        #expect(TestScript.audioCapture.steps.count == 16)
    }

    @Test("Transcription script has exactly 4 steps")
    func transcriptionStepCount() {
        #expect(TestScript.transcription.steps.count == 4)
    }

    @Test("Audio Capture step IDs match the canonical set")
    func audioCaptureStepIDs() {
        let ids = Set(TestScript.audioCapture.steps.map(\.id))
        let expected: Set = [
            "ac_request_permissions",
            "ac_two_dialogs",
            "ac_timed_capture",
            "ac_start_recording",
            "ac_stop_recording",
            "ac_files_exist",
            "ac_playback_mic",
            "ac_playback_system",
            "ac_route_change",
            "ac_meet_close_midcapture",
            "ac_meet_open_midcapture",
            "ac_mega_setup",
            "ac_mega_voice",
            "ac_mega_timing",
            "ac_crash_safety_setup",
            "ac_crash_safety_check"
        ]
        #expect(ids == expected)
    }

    @Test("Transcription step IDs match the canonical set")
    func transcriptionStepIDs() {
        let ids = Set(TestScript.transcription.steps.map(\.id))
        let expected: Set = [
            "tx_clear_cache",
            "tx_model_download",
            "tx_model_disk",
            "tx_ai_test_passed"
        ]
        #expect(ids == expected)
    }

    @Test("Cut transcription steps are absent")
    func cutTranscriptionStepsAbsent() {
        let ids = Set(TestScript.transcription.steps.map(\.id))
        let cutIDs = [
            "tx_transcribe",
            "tx_speakers",
            "tx_no_hallucination",
            "tx_custom_vocab",
            "tx_crash_setup",
            "tx_crash_host_survives",
            "tx_crash_retry"
        ]
        for cutID in cutIDs {
            #expect(!ids.contains(cutID), "Cut step '\(cutID)' should not be in the transcription script")
        }
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

    @Test("Local LLM script has a non-empty id and title")
    func localLLMIdentity() {
        let script = TestScript.localLLM
        #expect(!script.id.isEmpty)
        #expect(!script.title.isEmpty)
        #expect(script.id == "local_llm")
    }

    @Test("Local LLM script has exactly 10 steps")
    func localLLMStepCount() {
        #expect(TestScript.localLLM.steps.count == 10)
    }

    @Test("Local LLM step IDs match the canonical set")
    func localLLMStepIDs() {
        let ids = Set(TestScript.localLLM.steps.map(\.id))
        let expected: Set = [
            "llm_model_download",
            "llm_model_disk",
            "llm_ai_tests_passed",
            "llm_xpc_inference",
            "llm_summarize_quality",
            "llm_action_items_quality",
            "llm_speaker_names_quality",
            "llm_thinking_mode",
            "llm_streaming_channels",
            "llm_reclamation"
        ]
        #expect(ids == expected)
    }

    @Test("Every step ID in Local LLM is non-empty")
    func localLLMStepIDsNonEmpty() {
        for step in TestScript.localLLM.steps {
            #expect(!step.id.isEmpty, "Empty step ID in Local LLM script")
        }
    }

    @Test("All step IDs across all scripts are unique")
    func allStepIDsUnique() {
        let allSteps = TestScript.audioCapture.steps
            + TestScript.transcription.steps
            + TestScript.localLLM.steps
        let ids = allSteps.map(\.id)
        let uniqueIDs = Set(ids)
        #expect(ids.count == uniqueIDs.count, "Duplicate step IDs found")
    }

    @Test("allScripts contains all scripts")
    func allScriptsContainsAll() {
        let ids = allScripts.map(\.id)
        #expect(ids.contains("audio_capture"))
        #expect(ids.contains("transcription"))
        #expect(ids.contains("local_llm"))
        #expect(allScripts.count == 3)
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

    @Test("Step IDs within Local LLM are unique")
    func localLLMInternalUniqueness() {
        let ids = TestScript.localLLM.steps.map(\.id)
        #expect(ids.count == Set(ids).count)
    }
}
