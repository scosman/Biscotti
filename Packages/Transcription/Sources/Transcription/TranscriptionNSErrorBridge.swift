import Foundation

/// Carries a typed ``TranscriptionError`` across the NSXPC boundary.
///
/// NSXPC sends an error as a plain `NSError`: domain, code and `userInfo` survive,
/// but a Swift error's associated values do not. A raw `TranscriptionError` reaches
/// the client as "Transcription.TranscriptionError error 5" with its detail string
/// lost, and `as? TranscriptionError` fails, so the client's error mapping is skipped.
///
/// Mirrors LocalLLM's `LLMNSErrorBridge`: the worker JSON-encodes the error into
/// `userInfo["payload"]` and the client decodes it back. It lives in the package
/// (not the XPC service's `main.swift`) so both directions are unit-tested.
public enum TranscriptionNSErrorBridge {
    /// NSError domain for `TranscriptionError`s wrapped for XPC transport.
    public static let errorDomain = "net.scosman.biscotti.Transcription"

    /// `userInfo` key holding the JSON-encoded ``TranscriptionError``.
    static let payloadKey = "payload"

    /// Wrap `error` for an XPC reply. Errors other than ``TranscriptionError``
    /// are sent as ``TranscriptionError/transcriptionFailed(_:)`` with their
    /// description, so the client always receives a typed error.
    public static func nsError(from error: any Error) -> NSError {
        let transcriptionError = error as? TranscriptionError
            ?? .transcriptionFailed(error.localizedDescription)
        var userInfo: [String: Any] = [
            NSLocalizedDescriptionKey: transcriptionError.localizedDescription
        ]
        if let payloadData = try? JSONEncoder().encode(transcriptionError) {
            userInfo[payloadKey] = payloadData
        }
        return NSError(domain: errorDomain, code: 1, userInfo: userInfo)
    }

    /// Decode a ``TranscriptionError`` from an XPC reply error, or `nil` if the
    /// error was not produced by ``nsError(from:)``.
    public static func transcriptionError(from error: any Error) -> TranscriptionError? {
        let nsError = error as NSError
        guard nsError.domain == errorDomain,
              let payloadData = nsError.userInfo[payloadKey] as? Data
        else { return nil }
        return try? JSONDecoder().decode(TranscriptionError.self, from: payloadData)
    }
}
