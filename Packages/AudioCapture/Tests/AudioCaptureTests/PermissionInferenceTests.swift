import Testing
@testable import AudioCapture

@Suite("PermissionInferenceTests")
struct PermissionInferenceTests {
    @Test("Returns true when checker reports all-zero")
    func returnsTrueWhenAllZero() async throws {
        let ctx = try TestRecorderFactory.make(probableDenied: true)
        defer { TestRecorderFactory.cleanup(ctx) }

        let denied = await ctx.recorder.probableSystemAudioDenied()
        #expect(denied == true)
    }

    @Test("Returns false when checker reports non-zero audio")
    func returnsFalseWhenNonZero() async throws {
        let ctx = try TestRecorderFactory.make(probableDenied: false)
        defer { TestRecorderFactory.cleanup(ctx) }

        let denied = await ctx.recorder.probableSystemAudioDenied()
        #expect(denied == false)
    }
}
