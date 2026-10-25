import Foundation
import Testing
@testable import Transcription

@Suite("XPCProcessRequest")
struct XPCProcessRequestTests {
    @Test("a payload without systemPath (single imported file) decodes with nil")
    func decodesWithoutSystemPath() throws {
        let json = #"{"micPath":"/a/imported.m4a","customVocabulary":["Biscotti"]}"#
        let request = try JSONDecoder().decode(XPCProcessRequest.self, from: Data(json.utf8))
        #expect(request.micPath == "/a/imported.m4a")
        #expect(request.systemPath == nil)
    }

    @Test("a legacy payload with both paths still decodes")
    func decodesLegacyPayload() throws {
        let json = #"{"micPath":"/a/mic.aac","systemPath":"/a/system.aac","customVocabulary":[]}"#
        let request = try JSONDecoder().decode(XPCProcessRequest.self, from: Data(json.utf8))
        #expect(request.systemPath == "/a/system.aac")
    }
}
