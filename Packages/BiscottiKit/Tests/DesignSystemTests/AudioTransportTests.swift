import Testing
@testable import DesignSystem

@Suite("AudioTransport -- formatRate")
struct FormatRateTests {
    @Test(
        "each speed option formats correctly",
        arguments: [
            (rate: Float(0.5), expected: "0.5\u{00D7}"),
            (rate: Float(1.0), expected: "1\u{00D7}"),
            (rate: Float(1.25), expected: "1.25\u{00D7}"),
            (rate: Float(1.5), expected: "1.5\u{00D7}"),
            (rate: Float(2.0), expected: "2\u{00D7}")
        ]
    )
    func formatRateValues(rate: Float, expected: String) {
        #expect(AudioTransport.formatRate(rate) == expected)
    }

    @Test("whole number rates omit decimal")
    func wholeNumberOmitsDecimal() {
        #expect(AudioTransport.formatRate(3.0) == "3\u{00D7}")
    }

    @Test("fractional rates preserve digits")
    func fractionalPreservesDigits() {
        #expect(AudioTransport.formatRate(0.75) == "0.75\u{00D7}")
    }
}
