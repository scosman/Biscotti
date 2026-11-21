import Foundation
import Testing
@testable import SpeakerFusion

/// Name spelling fixed after transcription.
struct HintCorrectorTests {
    /// A test call's vocabulary as Biscotti built it from the invite.
    static let hints = [
        "Kelbo", "Owen", "Chris", "Sam", "Nora", "Brooks", "mking@tailspin.example", "Dana", "Dale",
        "Beth", "Tailspinsecurity", "Fabrikam", "Vendorsecurity", "Northwindcompanies", "RYM", "Tailspin", "Passcode"
    ]

    static func words(_ texts: [String]) -> [FusionWord] {
        texts.enumerated().map { FusionWord(text: $1, start: Double($0), end: Double($0) + 0.4, clusterID: 0) }
    }

    static func corrected(_ texts: [String]) -> [String] {
        HintCorrector.correct(words(texts), hints: hints).words.map(\.text)
    }

    @Test func fixesNearMissesOfInviteNames() {
        #expect(Self.corrected([" I", " just", " sent", " the", " RIM", " team"]) == [" I", " just", " sent", " the", " RYM", " team"])
        #expect(Self.corrected([" Thanks,", " Kelbow."]) == [" Thanks,", " Kelbo."])
        #expect(Self.corrected([" Brookes's"]) == [" Brooks's"])
        #expect(Self.corrected([" tailspin"]) == [" Tailspin"])
    }

    @Test func leavesEverydayWordsShortNamesAndExactMatchesAlone() {
        let untouched = [" the", " rim", " of", " the", " cup", " Dan", " Sam", " Nora", " Fabrikam", " clear", " Ben"]
        #expect(Self.corrected(untouched) == untouched)
    }

    @Test func keepsTimingAndReportsWhatChanged() {
        let result = HintCorrector.correct(Self.words([" hello", " RIM"]), hints: Self.hints)
        #expect(result.words[1].start == 1)
        #expect(result.changes == [NameCorrection(time: 1, original: "RIM", replacement: "RYM")])
    }

    @Test func ambiguousMatchesAreSkipped() {
        let result = HintCorrector.correct(Self.words([" Jonson"]), hints: ["Johnson", "Jonsen"])
        #expect(result.changes.isEmpty)
    }
}
