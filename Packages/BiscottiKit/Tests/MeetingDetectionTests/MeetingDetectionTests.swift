import AudioCapture
import MeetingCatalog
import MeetingDetection
import Testing

// MARK: - Core heuristic tests

@Suite("MeetingDetection — Heuristic")
@MainActor
struct HeuristicTests {
    @Test("Emits started when watchlist app runs input and output")
    func emitsStartedForInputAndOutput() async {
        let source = FakeActivitySource()
        let catalog = FakeMeetingCatalog(
            meetingBundleIDs: ["us.zoom.xos"],
            displayNames: ["us.zoom.xos": "Zoom"]
        )
        let detector = makeImmediateDetector(
            catalog: catalog, source: source
        )
        let collector = EventCollector()
        collector.start(from: detector)
        detector.start()

        source.emit([
            makeProcess(
                bundleID: "us.zoom.xos",
                isRunningInput: true,
                isRunningOutput: true
            )
        ])
        await collector.waitForEvents(count: 1)

        #expect(collector.events == [
            .started(app: DetectedApp(
                bundleID: "us.zoom.xos", displayName: "Zoom"
            ))
        ])
        detector.stop()
        collector.cancel()
    }

    @Test("Output only does not trigger in-call")
    func outputOnlyNoEvent() async {
        let source = FakeActivitySource()
        let catalog = FakeMeetingCatalog(
            meetingBundleIDs: ["us.zoom.xos"],
            displayNames: ["us.zoom.xos": "Zoom"]
        )
        let detector = makeImmediateDetector(
            catalog: catalog, source: source
        )
        let collector = EventCollector()
        collector.start(from: detector)
        detector.start()

        source.emit([makeProcess(
            bundleID: "us.zoom.xos",
            isRunningInput: false,
            isRunningOutput: true
        )])
        await collector.settle()
        detector.stop()
        await collector.settle()
        collector.cancel()

        #expect(collector.events.isEmpty)
    }

    @Test("Input only does not trigger in-call")
    func inputOnlyNoEvent() async {
        let source = FakeActivitySource()
        let catalog = FakeMeetingCatalog(
            meetingBundleIDs: ["us.zoom.xos"],
            displayNames: ["us.zoom.xos": "Zoom"]
        )
        let detector = makeImmediateDetector(
            catalog: catalog, source: source
        )
        let collector = EventCollector()
        collector.start(from: detector)
        detector.start()

        source.emit([makeProcess(
            bundleID: "us.zoom.xos",
            isRunningInput: true,
            isRunningOutput: false
        )])
        await collector.settle()
        detector.stop()
        await collector.settle()
        collector.cancel()

        #expect(collector.events.isEmpty)
    }

    @Test("No event for non-watchlist app")
    func nonWatchlistNoEvent() async {
        let source = FakeActivitySource()
        let catalog = FakeMeetingCatalog(
            meetingBundleIDs: ["us.zoom.xos"],
            displayNames: ["us.zoom.xos": "Zoom"]
        )
        let detector = makeImmediateDetector(
            catalog: catalog, source: source
        )
        let collector = EventCollector()
        collector.start(from: detector)
        detector.start()

        source.emit([makeProcess(
            bundleID: "com.spotify.client",
            isRunningInput: true,
            isRunningOutput: true
        )])
        await collector.settle()
        detector.stop()
        await collector.settle()
        collector.cancel()

        #expect(collector.events.isEmpty)
    }

    @Test("Nil bundleID ignored")
    func nilBundleIDNoEvent() async {
        let source = FakeActivitySource()
        let catalog = FakeMeetingCatalog(
            meetingBundleIDs: ["us.zoom.xos"],
            displayNames: ["us.zoom.xos": "Zoom"]
        )
        let detector = makeImmediateDetector(
            catalog: catalog, source: source
        )
        let collector = EventCollector()
        collector.start(from: detector)
        detector.start()

        source.emit([makeProcess(
            bundleID: nil,
            isRunningInput: true,
            isRunningOutput: true
        )])
        await collector.settle()
        detector.stop()
        await collector.settle()
        collector.cancel()

        #expect(collector.events.isEmpty)
    }

    @Test("Duplicate start not emitted for continued presence")
    func duplicateStartSuppressed() async {
        let source = FakeActivitySource()
        let catalog = FakeMeetingCatalog(
            meetingBundleIDs: ["us.zoom.xos"],
            displayNames: ["us.zoom.xos": "Zoom"]
        )
        let detector = makeImmediateDetector(
            catalog: catalog, source: source
        )
        let collector = EventCollector()
        collector.start(from: detector)
        detector.start()

        let snapshot = [makeProcess(
            bundleID: "us.zoom.xos",
            isRunningInput: true,
            isRunningOutput: true
        )]
        source.emit(snapshot)
        await collector.waitForEvents(count: 1)

        source.emit(snapshot)
        await collector.settle()
        source.emit(snapshot)
        await collector.settle()

        detector.stop()
        await collector.settle()
        collector.cancel()

        let startedCount = collector.events.count(where: {
            if case .started = $0 { return true }; return false
        })
        #expect(startedCount == 1)
    }
}

// MARK: - Mic-user tracking tests

@Suite("MeetingDetection — Mic User Tracking")
@MainActor
struct MicUserTrackingTests {
    @Test("allMicUsersStopped fires when non-self mic users transition to zero")
    func allMicUsersStoppedFires() async {
        let source = FakeActivitySource()
        let catalog = FakeMeetingCatalog(
            meetingBundleIDs: ["us.zoom.xos"],
            displayNames: ["us.zoom.xos": "Zoom"]
        )
        let detector = makeImmediateDetector(
            catalog: catalog, source: source
        )
        let collector = EventCollector()
        collector.start(from: detector)
        detector.start()

        // Non-watchlist app using mic (not Biscotti)
        source.emit([makeProcess(
            bundleID: "com.spotify.client",
            isRunningInput: true,
            isRunningOutput: false
        )])
        await collector.settle()

        // Mic user stops
        source.emit([])
        await collector.settle()

        detector.stop()
        await collector.settle()
        collector.cancel()

        #expect(collector.events == [.allMicUsersStopped])
    }

    @Test("allMicUsersStopped does not fire for self (Biscotti) process")
    func selfProcessExcludedFromMicTracking() async {
        let source = FakeActivitySource()
        let catalog = FakeMeetingCatalog(
            meetingBundleIDs: ["us.zoom.xos"],
            displayNames: ["us.zoom.xos": "Zoom"]
        )
        let detector = MeetingDetector(
            catalog: catalog,
            source: source,
            clock: AnyClock(ImmediateClock()),
            selfBundlePrefix: "net.scosman.biscotti"
        )
        let collector = EventCollector()
        collector.start(from: detector)
        detector.start()

        // Only Biscotti using mic -- does NOT count as non-self
        source.emit([makeProcess(
            bundleID: "net.scosman.biscotti",
            isRunningInput: true,
            isRunningOutput: false
        )])
        await collector.settle()

        // Biscotti stops -- no transition because it was never a non-self user
        source.emit([])
        await collector.settle()

        detector.stop()
        await collector.settle()
        collector.cancel()

        #expect(collector.events.isEmpty)
    }

    @Test("allMicUsersStopped fires when non-self stops but self remains")
    func allMicStoppedWhileSelfRemains() async {
        let source = FakeActivitySource()
        let catalog = FakeMeetingCatalog(
            meetingBundleIDs: ["us.zoom.xos"],
            displayNames: ["us.zoom.xos": "Zoom"]
        )
        let detector = MeetingDetector(
            catalog: catalog,
            source: source,
            clock: AnyClock(ImmediateClock()),
            selfBundlePrefix: "net.scosman.biscotti"
        )
        let collector = EventCollector()
        collector.start(from: detector)
        detector.start()

        // Zoom + Biscotti both using mic
        source.emit([
            makeProcess(
                bundleID: "us.zoom.xos",
                isRunningInput: true,
                isRunningOutput: true,
                pid: 1
            ),
            makeProcess(
                bundleID: "net.scosman.biscotti",
                isRunningInput: true,
                isRunningOutput: false,
                pid: 2
            )
        ])
        await collector.waitForEvents(count: 1) // .started(Zoom)

        // Zoom stops but Biscotti remains -- allMicUsersStopped fires
        // because the only remaining mic user is self (excluded)
        source.emit([
            makeProcess(
                bundleID: "net.scosman.biscotti",
                isRunningInput: true,
                isRunningOutput: false,
                pid: 2
            )
        ])
        await collector.waitForEvents(count: 2)

        #expect(collector.events.count >= 2)
        #expect(collector.events.contains(.allMicUsersStopped))

        detector.stop()
        await collector.settle()
        collector.cancel()
    }

    @Test("allMicUsersStopped does not fire without prior mic users")
    func noTransitionWithoutPriorMicUsers() async {
        let source = FakeActivitySource()
        let catalog = FakeMeetingCatalog(
            meetingBundleIDs: ["us.zoom.xos"],
            displayNames: ["us.zoom.xos": "Zoom"]
        )
        let detector = makeImmediateDetector(
            catalog: catalog, source: source
        )
        let collector = EventCollector()
        collector.start(from: detector)
        detector.start()

        // Empty snapshots -- no mic users ever
        source.emit([])
        await collector.settle()
        source.emit([])
        await collector.settle()

        detector.stop()
        await collector.settle()
        collector.cancel()

        #expect(collector.events.isEmpty)
    }
}
