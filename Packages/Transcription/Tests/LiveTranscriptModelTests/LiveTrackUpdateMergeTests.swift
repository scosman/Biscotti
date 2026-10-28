import Foundation
import Testing
@testable import LiveTranscriptModel

@Suite("LiveTrackUpdate merge")
struct LiveTrackUpdateMergeTests {
    @Test("Merging keeps each row's latest version in time order and accumulates gaps")
    func mergeKeepsLatestRowVersionAndAccumulatesGaps() {
        let sessionID = UUID()
        let open = LiveRow(track: .mic, startTime: 1, endTime: 2, tailText: "hel")
        let firstGap = LiveGap(track: .mic, startTime: 0, duration: 0.5, reason: .captureGap)
        var pending = LiveTrackUpdate(
            sessionID: sessionID, generation: 1, track: .mic, revision: 1, rows: [open], gaps: [firstGap],
            transcribedThrough: 2, settledThrough: 1, detectedLanguage: "en", decodeMilliseconds: 40
        )

        var settled = open
        settled.settledText = "hello"
        settled.tailText = ""
        let earlier = LiveRow(track: .mic, startTime: 0.5, endTime: 0.8, settledText: "so")
        let secondGap = LiveGap(track: .mic, startTime: 3, duration: 1, reason: .queueOverflow)
        pending.merge(LiveTrackUpdate(
            sessionID: sessionID, generation: 1, track: .mic, revision: 3, rows: [settled, earlier], gaps: [secondGap],
            transcribedThrough: 3, settledThrough: 2.5
        ))

        #expect(pending.rows == [earlier, settled])
        #expect(pending.gaps == [firstGap, secondGap])
        #expect(pending.revision == 3)
        #expect(pending.transcribedThrough == 3)
        #expect(pending.settledThrough == 2.5)
        #expect(pending.detectedLanguage == "en", "A later update without a value keeps the earlier one")
        #expect(pending.decodeMilliseconds == 40)
    }
}
