import Foundation
import Testing
@testable import Transcription

@Suite("XPCProcessRequest codable round-trip")
struct XPCProcessRequestTests {
    @Test("round-trip with nil micPath preserves nil")
    func roundTripNilMic() throws {
        let request = XPCProcessRequest(
            micPath: nil,
            systemPath: "/audio/system.aac",
            customVocabulary: ["Biscotti"]
        )
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(XPCProcessRequest.self, from: data)

        #expect(decoded.micPath == nil)
        #expect(decoded.systemPath == "/audio/system.aac")
        #expect(decoded.customVocabulary == ["Biscotti"])
    }

    @Test("round-trip with nil systemPath preserves nil")
    func roundTripNilSystem() throws {
        let request = XPCProcessRequest(
            micPath: "/audio/mic.aac",
            systemPath: nil,
            customVocabulary: []
        )
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(XPCProcessRequest.self, from: data)

        #expect(decoded.micPath == "/audio/mic.aac")
        #expect(decoded.systemPath == nil)
        #expect(decoded.customVocabulary.isEmpty)
    }

    @Test("round-trip with both paths non-nil")
    func roundTripBothPresent() throws {
        let request = XPCProcessRequest(
            micPath: "/audio/mic.aac",
            systemPath: "/audio/system.aac",
            customVocabulary: ["WhisperKit"]
        )
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(XPCProcessRequest.self, from: data)

        #expect(decoded.micPath == "/audio/mic.aac")
        #expect(decoded.systemPath == "/audio/system.aac")
    }

    @Test("decode from JSON missing micPath key yields nil")
    func decodeMissingMicKeyIsNil() throws {
        let json = """
        {"systemPath": "/audio/system.aac", "customVocabulary": []}
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(XPCProcessRequest.self, from: data)

        #expect(decoded.micPath == nil)
        #expect(decoded.systemPath == "/audio/system.aac")
    }

    @Test("decode from JSON missing systemPath key yields nil")
    func decodeMissingSystemKeyIsNil() throws {
        let json = """
        {"micPath": "/audio/mic.aac", "customVocabulary": []}
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(XPCProcessRequest.self, from: data)

        #expect(decoded.micPath == "/audio/mic.aac")
        #expect(decoded.systemPath == nil)
    }

    @Test("round-trip with both paths nil")
    func roundTripBothNil() throws {
        let request = XPCProcessRequest(
            micPath: nil,
            systemPath: nil,
            customVocabulary: []
        )
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(XPCProcessRequest.self, from: data)

        #expect(decoded.micPath == nil)
        #expect(decoded.systemPath == nil)
    }
}
