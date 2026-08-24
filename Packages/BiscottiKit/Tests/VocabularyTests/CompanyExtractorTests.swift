import Testing
@testable import Vocabulary

@Suite("CompanyExtractor")
struct CompanyExtractorTests {
    @Test("Free-mail domains are stripped")
    func freeMailDomainsStripped() {
        let result = CompanyExtractor.companyNames(from: [
            "alice@gmail.com",
            "bob@acme.com",
            "charlie@yahoo.com"
        ])
        #expect(result == ["Acme"])
    }

    @Test("5 unique domains included (at cap)")
    func fiveDomainsCap() {
        let result = CompanyExtractor.companyNames(from: [
            "a@alpha.com", "b@bravo.com", "c@charlie.com",
            "d@delta.com", "e@echo.com"
        ])
        #expect(result.count == 5)
    }

    @Test("6 unique domains excluded (exceeds cap)")
    func sixDomainsExceedsCap() {
        let result = CompanyExtractor.companyNames(from: [
            "a@alpha.com", "b@bravo.com", "c@charlie.com",
            "d@delta.com", "e@echo.com", "f@foxtrot.com"
        ])
        #expect(result.isEmpty)
    }

    @Test("Domain cap applied after stripping free-mail")
    func domainCapAfterStripping() {
        // 5 corporate + 3 free-mail = 8 total, but only 5 unique non-free
        let result = CompanyExtractor.companyNames(from: [
            "a@alpha.com", "b@bravo.com", "c@charlie.com",
            "d@delta.com", "e@echo.com",
            "f@gmail.com", "g@yahoo.com", "h@hotmail.com"
        ])
        #expect(result.count == 5)
    }

    @Test("Public suffix handling: mail.acme.co.uk → Acme")
    func publicSuffixHandling() {
        let result = CompanyExtractor.companyNames(from: ["alice@mail.acme.co.uk"])
        #expect(result == ["Acme"])
    }

    @Test("Hyphenated domain: acme-corp.com → Acme Corp")
    func hyphenatedDomain() {
        let result = CompanyExtractor.companyNames(from: ["bob@acme-corp.com"])
        #expect(result == ["Acme Corp"])
    }

    @Test("Two-character label is skipped")
    func shortLabelSkipped() {
        let result = CompanyExtractor.companyNames(from: ["a@ab.com"])
        #expect(result.isEmpty)
    }

    @Test("www label is skipped")
    func wwwLabelSkipped() {
        // This is an unusual email but the spec says to skip "www".
        let result = CompanyExtractor.companyNames(from: ["a@www.com"])
        #expect(result.isEmpty)
    }

    @Test("Malformed email addresses are ignored")
    func malformedEmailsIgnored() {
        let result = CompanyExtractor.companyNames(from: [
            "not-an-email",
            "",
            "alice@acme.com"
        ])
        #expect(result == ["Acme"])
    }

    @Test("Duplicate domains produce one company name")
    func duplicateDomainsDeduped() {
        let result = CompanyExtractor.companyNames(from: [
            "alice@acme.com", "bob@acme.com"
        ])
        #expect(result == ["Acme"])
    }

    @Test("Domain is lowercased before comparison")
    func domainCaseInsensitive() {
        let result = CompanyExtractor.companyNames(from: [
            "alice@ACME.COM", "bob@acme.com"
        ])
        #expect(result == ["Acme"])
    }

    @Test("Simple two-part domain extracts the name")
    func simpleTwoPartDomain() {
        let result = CompanyExtractor.companyNames(from: ["dev@stripe.com"])
        #expect(result == ["Stripe"])
    }

    @Test("Multi-part public suffix com.au handled")
    func multiPartSuffixComAu() {
        let result = CompanyExtractor.companyNames(from: ["user@company.com.au"])
        #expect(result == ["Company"])
    }

    @Test("Empty email list returns empty")
    func emptyEmailList() {
        let result = CompanyExtractor.companyNames(from: [])
        #expect(result.isEmpty)
    }
}
