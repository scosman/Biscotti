import Foundation
import Testing

@testable import STTLabCore

@Suite("MemorySampler tests")
struct MemorySamplerTests {
    @Test func samplerReturnsNonZeroFootprint() async throws {
        let sampler = MemorySampler(interval: 0.1, watchSystemProcesses: false)
        await sampler.start()
        // Allocate some memory to ensure a measurable footprint
        let buffer = [UInt8](repeating: 42, count: 1_000_000)
        _ = buffer.count
        try await Task.sleep(for: .milliseconds(250))
        let report = await sampler.stop()

        #expect(report.sampleCount > 0)
        #expect(report.processPeakFootprintBytes != nil)
        if let peak = report.processPeakFootprintBytes {
            #expect(peak > 0)
        }
        #expect(report.sampleIntervalSeconds == 0.1)
    }
}
