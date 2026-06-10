/// Manages `ModelStatus` state transitions with validation.
///
/// Enforces a valid lifecycle: `needsDownload -> downloading -> compiling ->
/// loading -> ready -> running -> ready`. Error can be entered from most states,
/// and recovery from error returns to `needsDownload`.
public actor ModelStatusMachine {
    /// The current status.
    public private(set) var current: ModelStatus

    public init(initial: ModelStatus = .needsDownload) {
        current = initial
    }

    /// Attempt a transition to a new status.
    ///
    /// - Parameter newStatus: The desired next status.
    /// - Returns: `true` if the transition was valid and applied, `false` otherwise.
    @discardableResult
    public func transition(to newStatus: ModelStatus) -> Bool {
        guard isValidTransition(from: current, target: newStatus) else {
            return false
        }
        current = newStatus
        return true
    }

    /// Force the status to a value without validation.
    /// Use only for error recovery or test setup.
    public func forceSet(_ status: ModelStatus) {
        current = status
    }

    // MARK: - Transition rules

    private func isValidTransition(from: ModelStatus, target: ModelStatus) -> Bool {
        // Error can be entered from any state
        if target.isError { return true }

        // Recovery from error goes back to needsDownload only
        if from.isError { return target.isNeedsDownload }

        let tag = TransitionTag(from: from.tag, target: target.tag)
        return Self.validTransitions.contains(tag)
    }
}

// MARK: - Transition lookup

private extension ModelStatusMachine {
    struct TransitionTag: Hashable {
        let from: StatusTag
        let target: StatusTag
    }

    static let validTransitions: Set<TransitionTag> = [
        // Download lifecycle
        TransitionTag(from: .needsDownload, target: .downloading),
        TransitionTag(from: .downloading, target: .downloading), // progress updates
        TransitionTag(from: .downloading, target: .compiling),
        TransitionTag(from: .downloading, target: .loading), // skip compile (cached)
        TransitionTag(from: .compiling, target: .loading),
        TransitionTag(from: .loading, target: .ready),
        // Job lifecycle
        TransitionTag(from: .ready, target: .running),
        TransitionTag(from: .running, target: .ready),
        // Unload
        TransitionTag(from: .ready, target: .needsDownload),
        TransitionTag(from: .running, target: .needsDownload)
    ]
}

/// Discriminator tag for `ModelStatus` cases, stripping associated values.
private enum StatusTag: Hashable {
    case needsDownload, downloading, compiling, loading, ready, running, error
}

private extension ModelStatus {
    var tag: StatusTag {
        switch self {
        case .needsDownload: .needsDownload
        case .downloading: .downloading
        case .compiling: .compiling
        case .loading: .loading
        case .ready: .ready
        case .running: .running
        case .error: .error
        }
    }

    var isError: Bool {
        tag == .error
    }

    var isNeedsDownload: Bool {
        tag == .needsDownload
    }
}
