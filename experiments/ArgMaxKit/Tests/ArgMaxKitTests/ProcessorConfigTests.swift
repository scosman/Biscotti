import Foundation
import Testing
@testable import ArgMaxKit

@Suite("ProcessorConfig")
struct ProcessorConfigTests {

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
}
