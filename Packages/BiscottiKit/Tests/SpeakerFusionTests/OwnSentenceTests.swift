import Foundation
import Testing
@testable import SpeakerFusion

/// The rest of your sentence stays yours when a remote voice
/// overlaps it, but the next sentence isn't pulled in.
struct OwnSentenceTests {
    @Test func continuationStaysYoursUntilTheSentenceEnds() {
        // Cluster 1 is a remote voice; the last three words of "You're muted, Chris."
        // sit in it because a remote speaker overlapped.
        var words: [FusionWord] = []
        for index in 0 ..< 10 {
            words.append(FusionWord(text: " remote", start: Double(index), end: Double(index) + 0.4, clusterID: 1))
        }
        words.append(FusionWord(text: " You're", start: 11.0, end: 11.2, clusterID: 1))
        words.append(FusionWord(text: " muted,", start: 11.25, end: 11.5, clusterID: 1))
        words.append(FusionWord(text: " Chris.", start: 11.55, end: 11.8, clusterID: 1))
        words.append(FusionWord(text: " That's", start: 11.9, end: 12.1, clusterID: 1))
        var sources: [WordSource] = Array(repeating: .system, count: 10) + [.mic, .mic, .mic, .mic]
        let margin: [Double] = Array(repeating: -30, count: 10) + [27, 8, 8, 8]
        SpeakerFuser.keepRemoteVoicesRemote(&sources, words: words, margin: margin)
        #expect(Array(sources[10 ... 12]) == [.mic, .mic, .mic])
        #expect(sources[13] == .system)
    }
}
