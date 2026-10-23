import Foundation
import Testing
@testable import ImportExport

@Suite("StrictPercentEncoder")
struct EncoderTests {
    // MARK: - Individual characters

    @Test("Space encodes as %20")
    func spaceEncodes() {
        #expect(StrictPercentEncoder.encode("hello world") == "hello%20world")
    }

    @Test("Forward slash is encoded")
    func slashEncodes() {
        #expect(StrictPercentEncoder.encode("a/b") == "a%2Fb")
    }

    @Test("Plus is encoded (never used for space)")
    func plusEncodes() {
        #expect(StrictPercentEncoder.encode("a+b") == "a%2Bb")
    }

    @Test("Ampersand is encoded")
    func ampersandEncodes() {
        #expect(StrictPercentEncoder.encode("a&b") == "a%26b")
    }

    @Test("Hash is encoded")
    func hashEncodes() {
        #expect(StrictPercentEncoder.encode("a#b") == "a%23b")
    }

    @Test("Question mark is encoded")
    func questionMarkEncodes() {
        #expect(StrictPercentEncoder.encode("a?b") == "a%3Fb")
    }

    @Test("Equals is encoded")
    func equalsEncodes() {
        #expect(StrictPercentEncoder.encode("a=b") == "a%3Db")
    }

    @Test("Comma is encoded")
    func commaEncodes() {
        #expect(StrictPercentEncoder.encode("a,b") == "a%2Cb")
    }

    @Test("Newline is encoded")
    func newlineEncodes() {
        #expect(StrictPercentEncoder.encode("a\nb") == "a%0Ab")
    }

    @Test("Emoji is encoded (multi-byte)")
    func emojiEncodes() {
        let encoded = StrictPercentEncoder.encode("🎉")
        // U+1F389 = F0 9F 8E 89 in UTF-8
        #expect(encoded == "%F0%9F%8E%89")
    }

    @Test("CJK character is encoded")
    func cjkEncodes() {
        let encoded = StrictPercentEncoder.encode("会")
        // U+4F1A = E4 BC 9A in UTF-8
        #expect(encoded == "%E4%BC%9A")
    }

    @Test("Accented e (NFC) is encoded")
    func accentedNFC() {
        // é in NFC = U+00E9 = C3 A9
        let nfc = "\u{00E9}"
        #expect(StrictPercentEncoder.encode(nfc) == "%C3%A9")
    }

    @Test("Accented e (NFD) is encoded")
    func accentedNFD() {
        // é in NFD = U+0065 U+0301 = 65 CC 81
        let nfd = "\u{0065}\u{0301}"
        #expect(StrictPercentEncoder.encode(nfd) == "e%CC%81")
    }

    // MARK: - Unreserved passthrough

    @Test("Unreserved characters pass through")
    func unreservedPassthrough() {
        let unreserved = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        #expect(StrictPercentEncoder.encode(unreserved) == unreserved)
    }

    // MARK: - Query builder

    @Test("Query joins key=value pairs with &")
    func queryJoining() {
        let result = StrictPercentEncoder.query([
            ("name", "My Note"),
            ("content", "hello & world")
        ])
        #expect(result == "name=My%20Note&content=hello%20%26%20world")
    }

    @Test("Empty query returns empty string")
    func emptyQuery() {
        #expect(StrictPercentEncoder.query([]) == "")
    }
}
