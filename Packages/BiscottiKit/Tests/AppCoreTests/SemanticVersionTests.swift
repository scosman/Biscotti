import Testing
@testable import AppCore

@Suite("SemanticVersion")
struct SemanticVersionTests {
    // MARK: - Parsing

    @Test("parses plain version")
    func parsePlain() {
        let ver = SemanticVersion("1.2.3")
        #expect(ver?.components == [1, 2, 3])
    }

    @Test("parses version with leading v")
    func parseLeadingV() {
        let ver = SemanticVersion("v1.2.3")
        #expect(ver?.components == [1, 2, 3])
    }

    @Test("parses version with leading V (uppercase)")
    func parseLeadingUppercaseV() {
        let ver = SemanticVersion("V2.0")
        #expect(ver?.components == [2, 0])
    }

    @Test("strips pre-release suffix after dash")
    func stripDashSuffix() {
        let ver = SemanticVersion("v2.0.0-beta")
        #expect(ver?.components == [2, 0, 0])
    }

    @Test("strips build metadata after plus")
    func stripPlusSuffix() {
        let ver = SemanticVersion("1.0.0+build.42")
        #expect(ver?.components == [1, 0, 0])
    }

    @Test("strips dash before plus")
    func stripDashBeforePlus() {
        let ver = SemanticVersion("v3.1.0-rc.1+meta")
        #expect(ver?.components == [3, 1, 0])
    }

    @Test("parses single component")
    func parseSingleComponent() {
        let ver = SemanticVersion("5")
        #expect(ver?.components == [5])
    }

    @Test("parses two components")
    func parseTwoComponents() {
        let ver = SemanticVersion("v2.0")
        #expect(ver?.components == [2, 0])
    }

    @Test("parses many components")
    func parseManyComponents() {
        let ver = SemanticVersion("1.2.3.4.5")
        #expect(ver?.components == [1, 2, 3, 4, 5])
    }

    @Test("trims whitespace")
    func trimsWhitespace() {
        let ver = SemanticVersion("  v1.0.0  ")
        #expect(ver?.components == [1, 0, 0])
    }

    // MARK: - Invalid input (fail closed)

    @Test("returns nil for empty string")
    func nilForEmpty() {
        #expect(SemanticVersion("") == nil)
    }

    @Test("returns nil for whitespace only")
    func nilForWhitespace() {
        #expect(SemanticVersion("   ") == nil)
    }

    @Test("returns nil for bare v")
    func nilForBareV() {
        #expect(SemanticVersion("v") == nil)
    }

    @Test("returns nil for non-numeric component")
    func nilForAlpha() {
        #expect(SemanticVersion("v1.abc.3") == nil)
    }

    @Test("returns nil for negative component")
    func nilForNegative() {
        #expect(SemanticVersion("1.-2.3") == nil)
    }

    @Test("returns nil for junk string")
    func nilForJunk() {
        #expect(SemanticVersion("not-a-version") == nil)
    }

    @Test("returns nil for empty component between dots")
    func nilForEmptyComponent() {
        #expect(SemanticVersion("1..3") == nil)
    }

    // MARK: - Comparison

    @Test("equal versions")
    func equalVersions() throws {
        let lhs = try #require(SemanticVersion("1.2.3"))
        let rhs = try #require(SemanticVersion("v1.2.3"))
        #expect(lhs == rhs)
        #expect(!(lhs < rhs))
        #expect(!(lhs > rhs))
    }

    @Test("missing trailing components equal zero")
    func missingTrailingEqualsZero() throws {
        let lhs = try #require(SemanticVersion("v2.0"))
        let rhs = try #require(SemanticVersion("v2.0.0"))
        #expect(lhs == rhs)
    }

    @Test("v10.1.2 > v2.0 (numeric, not lexicographic)")
    func numericNotLexicographic() throws {
        let lhs = try #require(SemanticVersion("v10.1.2"))
        let rhs = try #require(SemanticVersion("v2.0"))
        #expect(lhs > rhs)
    }

    @Test("patch version bump")
    func patchBump() throws {
        let lhs = try #require(SemanticVersion("1.0.0"))
        let rhs = try #require(SemanticVersion("1.0.1"))
        #expect(lhs < rhs)
    }

    @Test("minor version bump")
    func minorBump() throws {
        let lhs = try #require(SemanticVersion("1.0.9"))
        let rhs = try #require(SemanticVersion("1.1.0"))
        #expect(lhs < rhs)
    }

    @Test("major version bump")
    func majorBump() throws {
        let lhs = try #require(SemanticVersion("1.9.9"))
        let rhs = try #require(SemanticVersion("2.0.0"))
        #expect(lhs < rhs)
    }

    @Test("pre-release suffix is stripped before comparison")
    func preReleaseSuffixStripped() throws {
        let lhs = try #require(SemanticVersion("v2.0.0-beta"))
        let rhs = try #require(SemanticVersion("v2.0.0"))
        #expect(lhs == rhs)
    }

    @Test("different component counts: shorter is less if missing = 0")
    func differentComponentCounts() throws {
        let lhs = try #require(SemanticVersion("2.0"))
        let rhs = try #require(SemanticVersion("2.0.1"))
        #expect(lhs < rhs)
    }

    // MARK: - Display

    @Test("displayString adds leading v")
    func displayStringWithV() throws {
        let ver = try #require(SemanticVersion("2.0.1"))
        #expect(ver.displayString == "v2.0.1")
    }

    @Test("displayString preserves all components")
    func displayStringPreservesComponents() throws {
        let ver = try #require(SemanticVersion("v10.1.2"))
        #expect(ver.displayString == "v10.1.2")
    }

    @Test("displayString for single component")
    func displayStringSingleComponent() throws {
        let ver = try #require(SemanticVersion("3"))
        #expect(ver.displayString == "v3")
    }
}
