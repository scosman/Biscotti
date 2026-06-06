import Foundation
import Testing
@testable import Transcription

@Suite("ProcessorConfig")
struct ConfigTests {
    @Test("Default config has expected values")
    func defaultConfig() {
        let config = ProcessorConfig.default

        #expect(config.sttModel == "large-v3_turbo")
        #expect(config.sttModelRepo == "argmaxinc/whisperkit-coreml")
        #expect(config.enableWordTimestamps == true)
        #expect(config.diarizationStrategy == .subsegment)
        #expect(config.sequentialLoading == false)
    }

    @Test("Custom config preserves all values")
    func customConfig() {
        let config = ProcessorConfig(
            sttModel: "large-v3_turbo_1307MB",
            sttModelRepo: "custom/repo",
            enableWordTimestamps: false,
            diarizationStrategy: .segment,
            sequentialLoading: true
        )

        #expect(config.sttModel == "large-v3_turbo_1307MB")
        #expect(config.sttModelRepo == "custom/repo")
        #expect(config.enableWordTimestamps == false)
        #expect(config.diarizationStrategy == .segment)
        #expect(config.sequentialLoading == true)
    }

    @Test("ProcessorConfig round-trips through Codable")
    func configCodable() throws {
        let original = ProcessorConfig(
            sttModel: "large-v3_turbo_1307MB",
            sttModelRepo: "argmaxinc/whisperkit-coreml",
            enableWordTimestamps: false,
            diarizationStrategy: .segment,
            sequentialLoading: true
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ProcessorConfig.self, from: data)

        #expect(decoded == original)
    }

    @Test("DiarizationStrategy raw values are correct")
    func diarizationStrategyRawValues() {
        #expect(DiarizationStrategy.subsegment.rawValue == "subsegment")
        #expect(DiarizationStrategy.segment.rawValue == "segment")
    }

    @Test("DiarizationStrategy can be decoded from raw strings")
    func diarizationStrategyFromRaw() {
        #expect(DiarizationStrategy(rawValue: "subsegment") == .subsegment)
        #expect(DiarizationStrategy(rawValue: "segment") == .segment)
        #expect(DiarizationStrategy(rawValue: "invalid") == nil)
    }

    @Test("DiarizationStrategy has exactly two cases")
    func diarizationStrategyCaseCount() {
        #expect(DiarizationStrategy.allCases.count == 2)
    }

    // MARK: - ramAware factory

    @Test("ramAware picks quantized model and sequential loading at 8 GB")
    func ramAwareAt8GB() {
        let eightGB: UInt64 = 8 * 1024 * 1024 * 1024
        let config = ProcessorConfig.ramAware(physicalMemory: eightGB)

        #expect(config.sttModel == "large-v3_turbo_1307MB")
        #expect(config.sequentialLoading == true)
        // Other defaults should still be default
        #expect(config.sttModelRepo == "argmaxinc/whisperkit-coreml")
        #expect(config.enableWordTimestamps == true)
        #expect(config.diarizationStrategy == .subsegment)
    }

    @Test("ramAware picks full-precision model at 16 GB")
    func ramAwareAt16GB() {
        let sixteenGB: UInt64 = 16 * 1024 * 1024 * 1024
        let config = ProcessorConfig.ramAware(physicalMemory: sixteenGB)

        #expect(config.sttModel == "large-v3_turbo")
        #expect(config.sequentialLoading == false)
    }

    @Test("ramAware picks quantized model below 8 GB")
    func ramAwareBelow8GB() {
        let fourGB: UInt64 = 4 * 1024 * 1024 * 1024
        let config = ProcessorConfig.ramAware(physicalMemory: fourGB)

        #expect(config.sttModel == "large-v3_turbo_1307MB")
        #expect(config.sequentialLoading == true)
    }

    @Test("ramAware picks full-precision model above 8 GB")
    func ramAwareAbove8GB() {
        let twelveGB: UInt64 = 12 * 1024 * 1024 * 1024
        let config = ProcessorConfig.ramAware(physicalMemory: twelveGB)

        #expect(config.sttModel == "large-v3_turbo")
        #expect(config.sequentialLoading == false)
    }
}
