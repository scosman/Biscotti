import CoreAudio

/// The default input and output devices a mic engine was built for.
/// Voice processing uses both: the input for capture, the output as the
/// echo reference (and `ensureOutputRateMatchesInput` sets its rate).
struct MicRoute: Equatable {
    let inputID: AudioObjectID
    let outputID: AudioObjectID

    /// The current default devices, or nil if either cannot be read.
    static func currentDefault() -> MicRoute? {
        guard let inputID = CoreAudioHelpers.defaultInputDeviceID(), inputID != 0,
              let outputID = CoreAudioHelpers.defaultOutputDeviceID(), outputID != 0
        else { return nil }
        return MicRoute(inputID: inputID, outputID: outputID)
    }
}

extension MicRoute: CustomStringConvertible {
    var description: String {
        "input=\(inputID) output=\(outputID)"
    }
}

/// What a mic reconnect request does with the current engine.
enum MicReconnectDecision: Equatable {
    /// The engine is running on the current route and delivers audio.
    case keepEngine
    /// The engine is running on the current route but its tap has not
    /// delivered audio yet (a rebuild has just started it). Keep it only if
    /// audio arrives within a short wait.
    case awaitFirstBuffer
    /// The route differs from the one the engine was built for, the engine
    /// stopped, or the route is unknown.
    case rebuild
}

/// Decides whether a mic reconnect request needs a rebuild. Pure, so the
/// decision is testable without hardware.
///
/// Requests can be stale. When AirPods are removed, macOS can move the
/// default devices between AirPods and the built-in devices several times
/// in about 2 s. `AudioRecorder` handles each input change in turn, after
/// the previous rebuild has finished. Each voice-processing rebuild stops
/// mic audio for 2–4 s, so a rebuild for a route the engine already uses
/// only adds a gap.
enum MicReconnectPolicy {
    /// Keeps the engine only when it runs on the route it was built for:
    /// `.keepEngine` once its tap has delivered audio, `.awaitFirstBuffer`
    /// before that. A changed or unknown route, or a stopped engine, needs
    /// a rebuild.
    static func decide(
        builtRoute: MicRoute?,
        currentRoute: MicRoute?,
        isRunning: Bool,
        hasDeliveredAudio: Bool
    ) -> MicReconnectDecision {
        guard let builtRoute, let currentRoute, builtRoute == currentRoute, isRunning else {
            return .rebuild
        }
        return hasDeliveredAudio ? .keepEngine : .awaitFirstBuffer
    }
}
