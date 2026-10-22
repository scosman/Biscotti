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

    @Test func samplerWithSystemProcessesDoesNotCrash() async throws {
        let sampler = MemorySampler(interval: 0.1, watchSystemProcesses: true)
        await sampler.start()
        try await Task.sleep(for: .milliseconds(250))
        let report = await sampler.stop()

        #expect(report.sampleCount > 0)
        // System processes may or may not contain speech processes;
        // verify the code path runs without error and all entries have valid fields.
        for proc in report.systemProcesses {
            #expect(proc.peakFootprintBytes > 0)
            #expect(!proc.name.isEmpty)
            // lifetimeMaxFootprintBytes is set from ri_lifetime_max_phys_footprint
            // when available; it should be non-nil for any process we successfully sampled.
            if proc.lifetimeMaxFootprintBytes != nil {
                #expect(proc.lifetimeMaxFootprintBytes! > 0)
            }
        }
    }

    @Test func lifetimePeakIsPopulated() async throws {
        let sampler = MemorySampler(interval: 0.1, watchSystemProcesses: false)
        await sampler.start()
        try await Task.sleep(for: .milliseconds(150))
        let report = await sampler.stop()

        // The process lifetime peak should always be available and at least as large as the sampled peak
        #expect(report.processLifetimePeakBytes != nil)
        if let lifetime = report.processLifetimePeakBytes, let peak = report.processPeakFootprintBytes {
            #expect(lifetime >= peak)
        }
    }
}
