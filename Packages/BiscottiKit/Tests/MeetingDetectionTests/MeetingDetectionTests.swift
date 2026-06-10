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
