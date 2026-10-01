import Testing
@testable import Vocabulary

@Suite("VocabularyLimits")
struct VocabularyLimitsTests {
    @Test("Limits have expected values")
    func limitsAreReasonable() {
        #expect(VocabularyLimits.maxUserTerms == 12)
        #expect(VocabularyLimits.maxEffectiveTerms == 40)
        #expect(VocabularyLimits.maxJoinedCharacters == 700)
        #expect(VocabularyLimits.maxSingleTermLength == 60)
        #expect(VocabularyLimits.maxInvitees == 20)
        #expect(VocabularyLimits.maxUniqueDomains == 5)
        #expect(VocabularyLimits.minTokenLength == 3)
        #expect(VocabularyLimits.minNameLength == 2)
        #expect(VocabularyLimits.shortTextHitRateCeiling == 0.34)
        #expect(VocabularyLimits.shortTextWordCount == 5)
        #expect(VocabularyLimits.longTextHitRateCeiling == 0.25)
    }
}
