import Testing
@testable import Transcription

@Suite("ModelStatusMachine")
struct StatusMachineTests {
    // MARK: - Full lifecycle

    @Test("Full lifecycle: needsDownload -> downloading -> compiling -> loading -> ready -> running -> ready")
    func fullLifecycle() async {
        let machine = ModelStatusMachine()

        #expect(await machine.current == .needsDownload)

        #expect(await machine.transition(to: .downloading(progress: 0.0)) == true)
        #expect(await machine.current == .downloading(progress: 0.0))

        #expect(await machine.transition(to: .downloading(progress: 0.5)) == true)
        #expect(await machine.current == .downloading(progress: 0.5))

        #expect(await machine.transition(to: .downloading(progress: 1.0)) == true)
        #expect(await machine.current == .downloading(progress: 1.0))

        #expect(await machine.transition(to: .compiling) == true)
        #expect(await machine.current == .compiling)

        #expect(await machine.transition(to: .loading) == true)
        #expect(await machine.current == .loading)

        #expect(await machine.transition(to: .ready) == true)
        #expect(await machine.current == .ready)

        #expect(await machine.transition(to: .running) == true)
        #expect(await machine.current == .running)

        #expect(await machine.transition(to: .ready) == true)
        #expect(await machine.current == .ready)
    }

    @Test("Skip compiling (cached models): downloading -> loading -> ready")
    func skipCompiling() async {
        let machine = ModelStatusMachine()

        #expect(await machine.transition(to: .downloading(progress: 0.0)) == true)
        #expect(await machine.transition(to: .downloading(progress: 1.0)) == true)
        #expect(await machine.transition(to: .loading) == true)
        #expect(await machine.transition(to: .ready) == true)
        #expect(await machine.current == .ready)
    }

    // MARK: - Progress updates within downloading

    @Test("Multiple progress updates within downloading are valid")
    func progressUpdates() async {
        let machine = ModelStatusMachine()
        await machine.transition(to: .downloading(progress: 0.0))

        #expect(await machine.transition(to: .downloading(progress: 0.25)) == true)
        #expect(await machine.transition(to: .downloading(progress: 0.50)) == true)
        #expect(await machine.transition(to: .downloading(progress: 0.75)) == true)
        #expect(await machine.transition(to: .downloading(progress: 1.0)) == true)
    }

    // MARK: - Unload

    @Test("Unload from ready returns to needsDownload")
    func unloadFromReady() async {
        let machine = ModelStatusMachine(initial: .ready)

        #expect(await machine.transition(to: .needsDownload) == true)
        #expect(await machine.current == .needsDownload)
    }

    @Test("Unload from running returns to needsDownload")
    func unloadFromRunning() async {
        let machine = ModelStatusMachine(initial: .running)

        #expect(await machine.transition(to: .needsDownload) == true)
        #expect(await machine.current == .needsDownload)
    }

    // MARK: - Error transitions

    @Test("Error can be entered from any state")
    func errorFromAnyState() async {
        let error = TranscriptionError.downloadFailed("test")

        for initialState: ModelStatus in [
            .needsDownload,
            .downloading(progress: 0.5),
            .compiling,
            .loading,
            .ready,
            .running
        ] {
            let machine = ModelStatusMachine(initial: initialState)
            #expect(await machine.transition(to: .error(error)) == true)
            #expect(await machine.current == .error(error))
        }
    }

    @Test("Recovery from error goes to needsDownload")
    func errorRecovery() async {
        let machine = ModelStatusMachine(
            initial: .error(.downloadFailed("network issue"))
        )

        #expect(await machine.transition(to: .needsDownload) == true)
        #expect(await machine.current == .needsDownload)
    }

    @Test("After error recovery, can start full lifecycle again")
    func errorRecoveryThenLifecycle() async {
        let machine = ModelStatusMachine(
            initial: .error(.downloadFailed("transient"))
        )

        #expect(await machine.transition(to: .needsDownload) == true)
        #expect(await machine.transition(to: .downloading(progress: 0.0)) == true)
        #expect(await machine.transition(to: .compiling) == true)
        #expect(await machine.transition(to: .loading) == true)
        #expect(await machine.transition(to: .ready) == true)
    }

    // MARK: - Invalid transitions

    @Test("Cannot skip from needsDownload to compiling")
    func cannotSkipToCompiling() async {
        let machine = ModelStatusMachine()

        #expect(await machine.transition(to: .compiling) == false)
        #expect(await machine.current == .needsDownload)
    }

    @Test("Cannot skip from needsDownload to loading")
    func cannotSkipToLoading() async {
        let machine = ModelStatusMachine()

        #expect(await machine.transition(to: .loading) == false)
        #expect(await machine.current == .needsDownload)
    }

    @Test("Cannot skip from needsDownload to ready")
    func cannotSkipToReady() async {
        let machine = ModelStatusMachine()

        #expect(await machine.transition(to: .ready) == false)
        #expect(await machine.current == .needsDownload)
    }

    @Test("Cannot skip from needsDownload to running")
    func cannotSkipToRunning() async {
        let machine = ModelStatusMachine()

        #expect(await machine.transition(to: .running) == false)
        #expect(await machine.current == .needsDownload)
    }

    @Test("Cannot go from loading to downloading")
    func cannotGoBackFromLoading() async {
        let machine = ModelStatusMachine(initial: .loading)

        #expect(await machine.transition(to: .downloading(progress: 0.0)) == false)
        #expect(await machine.current == .loading)
    }

    @Test("Cannot go from ready to downloading")
    func cannotGoBackFromReady() async {
        let machine = ModelStatusMachine(initial: .ready)

        #expect(await machine.transition(to: .downloading(progress: 0.0)) == false)
        #expect(await machine.current == .ready)
    }

    @Test("Cannot go from compiling to downloading")
    func cannotGoBackFromCompiling() async {
        let machine = ModelStatusMachine(initial: .compiling)

        #expect(await machine.transition(to: .downloading(progress: 0.0)) == false)
        #expect(await machine.current == .compiling)
    }

    @Test("Cannot go from error to downloading directly")
    func cannotGoFromErrorToDownloading() async {
        let machine = ModelStatusMachine(
            initial: .error(.downloadFailed("test"))
        )

        #expect(await machine.transition(to: .downloading(progress: 0.0)) == false)
        #expect(await machine.current == .error(.downloadFailed("test")))
    }

    @Test("Cannot go from running to loading")
    func cannotGoFromRunningToLoading() async {
        let machine = ModelStatusMachine(initial: .running)

        #expect(await machine.transition(to: .loading) == false)
    }

    // MARK: - forceSet

    @Test("forceSet overrides current status without validation")
    func forceSetOverrides() async {
        let machine = ModelStatusMachine()

        await machine.forceSet(.ready)
        #expect(await machine.current == .ready)
    }

    // MARK: - Initial state

    @Test("Default initial state is needsDownload")
    func defaultInitialState() async {
        let machine = ModelStatusMachine()
        #expect(await machine.current == .needsDownload)
    }

    @Test("Custom initial state is respected")
    func customInitialState() async {
        let machine = ModelStatusMachine(initial: .ready)
        #expect(await machine.current == .ready)
    }
}
