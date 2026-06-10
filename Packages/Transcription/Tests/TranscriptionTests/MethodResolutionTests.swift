import Foundation
import Testing
@testable import Transcription

@Suite("Method resolution")
struct MethodResolutionTests {
    @Test("current method id is v1")
    func currentIsV1() {
        #expect(TranscriptionMethod.current.id == "v1")
        #expect(TranscriptionMethod.v1.id == "v1")
    }

    // MARK: - RAM-aware resolution (now internal to the method resolver)

    @Test("v1 resolves to the single STT model + sequential loading at 8 GB")
    func resolvesWithSequentialLoadingAt8GB() {
        let eightGB: UInt64 = 8 * 1024 * 1024 * 1024
        let settings = MethodResolver.resolve(.v1, physicalMemory: eightGB)

        #expect(settings.sttModel == MethodResolver.sttModel)
        #expect(settings.sequentialLoading == true)
        // Non-RAM-dependent settings are fixed for v1.
        #expect(settings.sttModelRepo == MethodResolver.defaultRepo)
        #expect(settings.enableWordTimestamps == true)
        #expect(settings.diarizationStrategy == .subsegment)
    }

    @Test("v1 resolves to the single STT model + sequential loading below 8 GB")
    func resolvesWithSequentialLoadingBelow8GB() {
        let fourGB: UInt64 = 4 * 1024 * 1024 * 1024
        let settings = MethodResolver.resolve(.v1, physicalMemory: fourGB)

        #expect(settings.sttModel == MethodResolver.sttModel)
        #expect(settings.sequentialLoading == true)
    }

    @Test("v1 resolves to the single STT model + no sequential loading at 16 GB")
    func resolvesNoSequentialLoadingAt16GB() {
        let sixteenGB: UInt64 = 16 * 1024 * 1024 * 1024
        let settings = MethodResolver.resolve(.v1, physicalMemory: sixteenGB)

        #expect(settings.sttModel == MethodResolver.sttModel)
        #expect(settings.sequentialLoading == false)
    }

    @Test("v1 resolves to the single STT model + no sequential loading above 8 GB")
    func resolvesNoSequentialLoadingAbove8GB() {
        let twelveGB: UInt64 = 12 * 1024 * 1024 * 1024
        let settings = MethodResolver.resolve(.v1, physicalMemory: twelveGB)

        #expect(settings.sttModel == MethodResolver.sttModel)
        #expect(settings.sequentialLoading == false)
    }

    @Test("unknown method id falls back to v1 behavior")
    func unknownFallsBackToV1() {
        let sixteenGB: UInt64 = 16 * 1024 * 1024 * 1024
        let settings = MethodResolver.resolve(
            TranscriptionMethod(id: "v999"), physicalMemory: sixteenGB
        )

        #expect(settings.sttModel == MethodResolver.sttModel)
        #expect(settings.diarizationStrategy == .subsegment)
    }
}
