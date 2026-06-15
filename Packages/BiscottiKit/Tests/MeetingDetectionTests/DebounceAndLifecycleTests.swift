import AudioCapture
import MeetingCatalog
import MeetingDetection
import Testing

// MARK: - Debounce tests

@Suite("MeetingDetection — Debounce")
@MainActor
struct DebounceTests {
    @Test("Start debounce reset on dropout")
    func startDebounceResetOnDropout() async {
        let source = FakeActivitySource()
        let catalog = FakeMeetingCatalog(
            meetingBundleIDs: ["us.zoom.xos"],
            displayNames: ["us.zoom.xos": "Zoom"]
        )
        let detector = makeNeverDetector(
            catalog: catalog, source: source
        )
        let collector = EventCollector()
        collector.start(from: detector)
        detector.start()

        source.emit([makeProcess(
            bundleID: "us.zoom.xos",
            isRunningInput: true,
            isRunningOutput: true
        )])
        await collector.settle()

        source.emit([makeProcess(
            bundleID: "us.zoom.xos",
            isRunningInput: false,
            isRunningOutput: false
        )])
        await collector.settle()

        detector.stop()
        await collector.settle()
        collector.cancel()

        #expect(collector.events.isEmpty)
    }

    @Test("Debounce suppresses flapping")
    func debounceSuppressesFlapping() async {
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
            isRunningOutput: true
        )])
        await collector.waitForEvents(count: 1)

        // Drop then immediately resume
        source.emit([makeProcess(
            bundleID: "us.zoom.xos",
            isRunningInput: false,
            isRunningOutput: false
        )])
        source.emit([makeProcess(
            bundleID: "us.zoom.xos",
            isRunningInput: true,
            isRunningOutput: true
        )])
        await collector.settle()

        detector.stop()
        await collector.settle()
        collector.cancel()

        let startedCount = collector.events.count(where: {
            if case .started = $0 { return true }; return false
        })
        #expect(startedCount == 1)
    }

    @Test("Stop debounce cancels on resume")
    func stopDebounceCancelsOnResume() async {
        let source = FakeActivitySource()
        let catalog = FakeMeetingCatalog(
            meetingBundleIDs: ["us.zoom.xos"],
            displayNames: ["us.zoom.xos": "Zoom"]
        )
        // Use OneShotImmediateClock: start debounce fires immediately
        // but stop debounce blocks until cancelled, ensuring the resume
        // snapshot cancels the pending stop deterministically.
        let detector = makeOneShotDetector(
            catalog: catalog, source: source
        )
        let collector = EventCollector()
        collector.start(from: detector)
        detector.start()

        source.emit([makeProcess(
            bundleID: "us.zoom.xos",
            isRunningInput: true,
            isRunningOutput: true
        )])
        await collector.waitForEvents(count: 1)

        source.emit([makeProcess(
            bundleID: "us.zoom.xos",
            isRunningInput: false,
            isRunningOutput: false
        )])
        source.emit([makeProcess(
            bundleID: "us.zoom.xos",
            isRunningInput: true,
            isRunningOutput: true
        )])
        await collector.settle()

        detector.stop()
        await collector.settle()
        collector.cancel()

        let zoom = DetectedApp(
            bundleID: "us.zoom.xos", displayName: "Zoom"
        )
        #expect(collector.events == [
            .started(app: zoom), .stopped(app: zoom)
        ])
    }
}

// MARK: - Stop & lifecycle tests

@Suite("MeetingDetection — Stop & Lifecycle")
@MainActor
struct StopAndLifecycleTests {
    @Test("Emits stopped when audio ceases")
    func stoppedWhenAudioCeases() async {
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
            isRunningOutput: true
        )])
        await collector.waitForEvents(count: 1)

        source.emit([makeProcess(
            bundleID: "us.zoom.xos",
            isRunningInput: false,
            isRunningOutput: false
        )])
        await collector.waitForEvents(count: 2)

        let zoom = DetectedApp(
            bundleID: "us.zoom.xos", displayName: "Zoom"
        )
        #expect(collector.events == [
            .started(app: zoom), .stopped(app: zoom)
        ])
        detector.stop()
        collector.cancel()
    }

    @Test("Process disappearance triggers stop")
    func processDisappearanceTriggers() async {
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
            isRunningOutput: true
        )])
        await collector.waitForEvents(count: 1)

        source.emit([])
        await collector.waitForEvents(count: 2)

        let zoom = DetectedApp(
            bundleID: "us.zoom.xos", displayName: "Zoom"
        )
        #expect(collector.events == [
            .started(app: zoom), .stopped(app: zoom)
        ])
        detector.stop()
        collector.cancel()
    }

    @Test("Stop on detector stop emits stopped and finishes")
    func stopOnDetectorStop() async {
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
            isRunningOutput: true
        )])
        await collector.waitForEvents(count: 1)

        detector.stop()
        await collector.settle()
        collector.cancel()

        let zoom = DetectedApp(
            bundleID: "us.zoom.xos", displayName: "Zoom"
        )
        #expect(collector.events == [
            .started(app: zoom), .stopped(app: zoom)
        ])
    }

    @Test("Concurrent meeting apps tracked independently")
    func concurrentApps() async {
        let source = FakeActivitySource()
        let catalog = FakeMeetingCatalog(
            meetingBundleIDs: ["us.zoom.xos", "com.tinyspeck.slackmacgap"],
            displayNames: ["us.zoom.xos": "Zoom", "com.tinyspeck.slackmacgap": "Slack"]
        )
        let detector = makeImmediateDetector(catalog: catalog, source: source)
        let collector = EventCollector()
        collector.start(from: detector)
        detector.start()

        source.emit([
            makeProcess(bundleID: "us.zoom.xos", isRunningInput: true, isRunningOutput: true, pid: 1),
            makeProcess(bundleID: "com.tinyspeck.slackmacgap", isRunningInput: true, isRunningOutput: true, pid: 2)
        ])
        await collector.waitForEvents(count: 2)
        #expect(collector.events.count == 2)

        let startedIDs = Set(collector.events.compactMap { event -> String? in
            if case let .started(app) = event { return app.bundleID }
            return nil
        })
        #expect(startedIDs == ["us.zoom.xos", "com.tinyspeck.slackmacgap"])

        // Stop Zoom only — Slack stays active
        source.emit([
            makeProcess(bundleID: "com.tinyspeck.slackmacgap", isRunningInput: true, isRunningOutput: true, pid: 2)
        ])
        await collector.waitForEvents(count: 3)
        #expect(collector.events[2] == .stopped(
            app: DetectedApp(bundleID: "us.zoom.xos", displayName: "Zoom")
        ))
        detector.stop()
        collector.cancel()
    }

    @Test("Events stream replaces on second call")
    func streamReplacesOnSecondCall() async {
        let source = FakeActivitySource()
        let catalog = FakeMeetingCatalog(
            meetingBundleIDs: ["us.zoom.xos"],
            displayNames: ["us.zoom.xos": "Zoom"]
        )
        let detector = makeImmediateDetector(
            catalog: catalog, source: source
        )

        let stream1 = detector.events()
        _ = detector.events() // replaces stream1

        var s1Events: [DetectionEvent] = []
        for await event in stream1 {
            s1Events.append(event)
        }
        #expect(s1Events.isEmpty)

        detector.stop()
    }
}
