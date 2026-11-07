import Foundation
import Testing
@testable import Transcription

@Suite("TranscriptionNSErrorBridge")
struct TranscriptionErrorBridgeTests {
    static let allCases: [TranscriptionError] = [
        .needsDownload,
        .insufficientDisk(requiredBytes: 2_000_000_000, availableBytes: 1000),
        .downloadFailed("network down"),
        .modelLoadFailed("bad weights"),
        .workerUnavailable,
        .workerInterrupted,
        .invalidInput("empty file"),
        .transcriptionFailed("decoder error"),
        .diarizationFailed("CoreML load failed")
    ]

    /// Encodes and decodes `error` with secure coding, as NSXPC does for reply errors.
    private func secureCodingRoundTrip(_ error: NSError) throws -> NSError {
        let data = try NSKeyedArchiver.archivedData(withRootObject: error, requiringSecureCoding: true)
        return try #require(try NSKeyedUnarchiver.unarchivedObject(ofClass: NSError.self, from: data))
    }

    @Test("every case survives the XPC round trip with its associated values", arguments: allCases)
    func roundTrip(_ error: TranscriptionError) throws {
        let transported = try secureCodingRoundTrip(TranscriptionNSErrorBridge.nsError(from: error))

        #expect(transported.domain == TranscriptionNSErrorBridge.errorDomain)
        #expect(TranscriptionNSErrorBridge.transcriptionError(from: transported) == error)
        #expect(transported.localizedDescription == error.localizedDescription)
    }

    @Test("a non-TranscriptionError is sent as transcriptionFailed with its description")
    func wrapsForeignError() {
        let underlying = NSError(
            domain: "SomeSDK", code: 42,
            userInfo: [NSLocalizedDescriptionKey: "something broke"]
        )
        let bridged = TranscriptionNSErrorBridge.nsError(from: underlying)

        #expect(TranscriptionNSErrorBridge.transcriptionError(from: bridged) == .transcriptionFailed("something broke"))
    }

    @Test("an error from another domain does not decode")
    func foreignDomainIsNil() {
        let error = NSError(domain: NSCocoaErrorDomain, code: 4097)
        #expect(TranscriptionNSErrorBridge.transcriptionError(from: error) == nil)
    }

    @Test("a bridge-domain error without a payload does not decode")
    func missingPayloadIsNil() {
        let error = NSError(domain: TranscriptionNSErrorBridge.errorDomain, code: 1)
        #expect(TranscriptionNSErrorBridge.transcriptionError(from: error) == nil)
    }

    @Test("errorDescription includes the detail text")
    func errorDescriptionIncludesDetail() {
        #expect(TranscriptionError.diarizationFailed("CoreML load failed")
            .localizedDescription.contains("CoreML load failed"))
        #expect(TranscriptionError.insufficientDisk(requiredBytes: 123, availableBytes: 45)
            .localizedDescription.contains("123"))
    }
}
