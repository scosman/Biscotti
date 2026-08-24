import Testing
@testable import Vocabulary

@Suite("CasingNormalizer")
struct CasingNormalizerTests {
    // MARK: - isAllUppercase

    @Test("Detects all-uppercase text")
    func allUppercaseDetected() {
        #expect(CasingNormalizer.isAllUppercase("HELLO WORLD"))
        #expect(CasingNormalizer.isAllUppercase("ABC"))
    }

    @Test("Mixed case is not all-uppercase")
    func mixedCaseNotAllUppercase() {
        #expect(!CasingNormalizer.isAllUppercase("Hello"))
        #expect(!CasingNormalizer.isAllUppercase("hELLO"))
    }

    @Test("Lowercase text is not all-uppercase")
    func lowercaseNotAllUppercase() {
        #expect(!CasingNormalizer.isAllUppercase("hello"))
    }

    @Test("Empty string is not all-uppercase")
    func emptyStringNotAllUppercase() {
        #expect(!CasingNormalizer.isAllUppercase(""))
    }

    @Test("Digits-only string is not all-uppercase (no cased letters)")
    func digitsOnlyNotAllUppercase() {
        #expect(!CasingNormalizer.isAllUppercase("123"))
    }

    @Test("Uppercase with digits is all-uppercase")
    func uppercaseWithDigits() {
        #expect(CasingNormalizer.isAllUppercase("ABC123"))
    }

    // MARK: - normalize

    @Test("All-uppercase source lowercases the term")
    func allUppercaseSourceLowercases() {
        let result = CasingNormalizer.normalize(
            forms: ["PARAKEET"], sourceIsAllUppercase: true
        )
        #expect(result == "parakeet")
    }

    @Test("Inconsistent casing across forms lowercases")
    func inconsistentCasingLowercases() {
        let result = CasingNormalizer.normalize(
            forms: ["Notion", "notion"], sourceIsAllUppercase: false
        )
        #expect(result == "notion")
    }

    @Test("Consistent casing is preserved verbatim")
    func consistentCasingPreserved() {
        let result = CasingNormalizer.normalize(
            forms: ["Parakeet"], sourceIsAllUppercase: false
        )
        #expect(result == "Parakeet")
    }

    @Test("Single occurrence preserves original casing including title-initial capital")
    func singleOccurrencePreserved() {
        let result = CasingNormalizer.normalize(
            forms: ["Kubernetes"], sourceIsAllUppercase: false
        )
        #expect(result == "Kubernetes")
    }

    @Test("Multiple identical forms count as consistent")
    func multipleIdenticalFormsConsistent() {
        let result = CasingNormalizer.normalize(
            forms: ["Parakeet", "Parakeet", "Parakeet"], sourceIsAllUppercase: false
        )
        #expect(result == "Parakeet")
    }

    @Test("Empty forms returns empty string")
    func emptyFormsReturnsEmpty() {
        let result = CasingNormalizer.normalize(forms: [], sourceIsAllUppercase: false)
        #expect(result == "")
    }
}
