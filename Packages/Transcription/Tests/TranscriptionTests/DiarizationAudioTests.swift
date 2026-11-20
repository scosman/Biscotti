import Foundation
import Testing
@testable import Transcription

/// Voices are separated on the call audio alone when there's
/// also a mic track.
struct DiarizationAudioTests {
    @Test func usesCallAudioWhenThereIsAMicTrack() {
        var merge = AudioLoading.MergeResult(samples: [0.5, 0.5, 0.5], duration: 1)
        merge.systemOnly = [0.2, 0.0, 0.2]
        #expect(InProcessTranscriptionEngine.diarizationAudio(merge) == [0.2, 0.0, 0.2])
    }

    @Test func fallsBackToTheMixWithoutCallAudio() {
        let inPerson = AudioLoading.MergeResult(samples: [0.5, 0.5], duration: 1)
        #expect(InProcessTranscriptionEngine.diarizationAudio(inPerson) == [0.5, 0.5])
        var silentCall = AudioLoading.MergeResult(samples: [0.5, 0.5], duration: 1)
        silentCall.systemOnly = [0, 0]
        #expect(InProcessTranscriptionEngine.diarizationAudio(silentCall) == [0.5, 0.5])
    }
}
