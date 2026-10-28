import Foundation

/// The Mac's power and heat, as the live transcript cares about them.
public struct PowerState: Equatable, Sendable {
    public var isLowPowerModeEnabled: Bool
    public var thermalState: ProcessInfo.ThermalState

    public init(isLowPowerModeEnabled: Bool = false, thermalState: ProcessInfo.ThermalState = .nominal) {
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
        self.thermalState = thermalState
    }
}

/// Where `PowerPolicy` reads the power state and hears it change.
public protocol PowerStateProviding: Sendable {
    var current: PowerState { get }
    func changes() -> AsyncStream<PowerState>
}

/// `ProcessInfo`'s Low Power Mode and thermal state, with their notifications.
public struct SystemPowerState: PowerStateProviding {
    public init() {}

    public var current: PowerState {
        PowerState(
            isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalState: ProcessInfo.processInfo.thermalState
        )
    }

    public func changes() -> AsyncStream<PowerState> {
        AsyncStream { continuation in
            let center = NotificationCenter.default
            let names: [Notification.Name] = [.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification]
            let observers = Observers(names.map { name in
                center.addObserver(forName: name, object: nil, queue: nil) { _ in
                    continuation.yield(SystemPowerState().current)
                }
            })
            continuation.onTermination = { _ in observers.remove(from: center) }
        }
    }

    /// `@unchecked`: the tokens are only handed back to the center that made them.
    private final class Observers: @unchecked Sendable {
        private let tokens: [any NSObjectProtocol]

        init(_ tokens: [any NSObjectProtocol]) {
            self.tokens = tokens
        }

        func remove(from center: NotificationCenter) {
            tokens.forEach(center.removeObserver)
        }
    }
}

/// Slows live transcription in Low Power Mode and pauses it while the Mac is
/// hot. Recording is never affected.
@MainActor
final class PowerPolicy {
    struct Decision: Equatable {
        /// Low Power Mode doubles the update interval.
        var intervalMultiplier: Double
        /// A serious or critical thermal state pauses the engine; nominal or
        /// fair resumes it.
        var isPaused: Bool

        init(_ state: PowerState) {
            intervalMultiplier = state.isLowPowerModeEnabled ? 2 : 1
            isPaused = state.thermalState == .serious || state.thermalState == .critical
        }

        init(intervalMultiplier: Double, isPaused: Bool) {
            self.intervalMultiplier = intervalMultiplier
            self.isPaused = isPaused
        }
    }

    private(set) var decision: Decision
    private var observer: Task<Void, Never>?

    /// Calls `onChange` on the MainActor whenever the decision changes.
    init(source: any PowerStateProviding, onChange: @escaping @MainActor (Decision) -> Void) {
        decision = Decision(source.current)
        let changes = source.changes()
        observer = Task { @MainActor [weak self] in
            for await state in changes {
                guard let self else { return }
                let next = Decision(state)
                guard next != decision else { continue }
                decision = next
                onChange(next)
            }
        }
    }
}
