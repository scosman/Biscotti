import Testing

@Suite("Levenshtein")
struct LevenshteinTests {
    // MARK: - distance

    @Test("identical strings have zero distance")
    func identicalStrings() {
        #expect(Levenshtein.distance("hello", "hello") == 0)
    }

    @Test("single insertion")
    func singleInsertion() {
        #expect(Levenshtein.distance("hello", "hellos") == 1)
    }

    @Test("single deletion")
    func singleDeletion() {
        #expect(Levenshtein.distance("hello", "hell") == 1)
    }

    @Test("single substitution")
    func singleSubstitution() {
        #expect(Levenshtein.distance("hello", "hallo") == 1)
    }

    @Test("empty vs non-empty")
    func emptyVsNonEmpty() {
        #expect(Levenshtein.distance("", "abc") == 3)
        #expect(Levenshtein.distance("abc", "") == 3)
    }

    @Test("both empty")
    func bothEmpty() {
        #expect(Levenshtein.distance("", "") == 0)
    }

    @Test("completely different strings")
    func completelyDifferent() {
        #expect(Levenshtein.distance("abc", "xyz") == 3)
    }

    @Test("known multi-edit case")
    func multiEdit() {
        // kitten -> sitting = 3 edits (k->s, e->i, +g)
        #expect(Levenshtein.distance("kitten", "sitting") == 3)
    }

    // MARK: - ratio

    @Test("identical strings have zero ratio")
    func ratioIdentical() {
        #expect(Levenshtein.ratio("hello", "hello") == 0.0)
    }

    @Test("both empty returns zero ratio")
    func ratioBothEmpty() {
        #expect(Levenshtein.ratio("", "") == 0.0)
    }

    @Test("completely different strings have ratio 1.0")
    func ratioCompletelyDifferent() {
        #expect(Levenshtein.ratio("abc", "xyz") == 1.0)
    }

    @Test("ratio is distance / max(len)")
    func ratioComputation() {
        // "hello" vs "hallo" = distance 1, max len 5
        let ratio = Levenshtein.ratio("hello", "hallo")
        #expect(ratio == 1.0 / 5.0)
    }

    @Test("ratio with different lengths uses the longer one")
    func ratioDifferentLengths() {
        // "hi" vs "hello" = distance 4, max len 5
        let ratio = Levenshtein.ratio("hi", "hello")
        #expect(ratio == 4.0 / 5.0)
    }

    @Test("small difference yields small ratio")
    func smallDifference() {
        // "hello world" (11 chars) vs "hello worl" (10 chars) = distance 1, max 11
        let ratio = Levenshtein.ratio("hello world", "hello worl")
        #expect(ratio < 0.1)
    }
}
