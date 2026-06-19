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

// MARK: - Mic-stop debounce tests

@Suite("MeetingDetection — Mic Stop Debounce")
@MainActor
struct MicStopDebounceTests {
    @Test("brief mic dropout (<5s) then reappearance does not emit allMicUsersStopped")
    func briefDropoutSuppressed() async {
        let source = FakeActivitySource()
        let catalog = FakeMeetingCatalog(
            meetingBundleIDs: ["us.zoom.xos"],
            displayNames: ["us.zoom.xos": "Zoom"]
        )
        // NeverClock: debounce timers never fire, so the brief dropout
        // remains pending and gets cancelled on reappearance.
        let detector = makeNeverDetector(
            catalog: catalog, source: source
        )
        let collector = EventCollector()
        collector.start(from: detector)
        detector.start()

        // Non-self mic user active
        source.emit([makeProcess(
            bundleID: "com.spotify.client",
            isRunningInput: true,
            isRunningOutput: false
        )])
        await collector.settle()

        // Mic user drops out
        source.emit([])
        await collector.settle()

        // Mic user comes back before debounce fires
        source.emit([makeProcess(
            bundleID: "com.spotify.client",
            isRunningInput: true,
            isRunningOutput: false
        )])
        await collector.settle()

        detector.stop()
        await collector.settle()
        collector.cancel()

        // No allMicUsersStopped -- the dropout was too brief
        #expect(collector.events.isEmpty)
    }

    @Test("sustained mic stop (>=5s) emits allMicUsersStopped exactly once")
    func sustainedStopEmitsOnce() async {
        let source = FakeActivitySource()
        let catalog = FakeMeetingCatalog(
            meetingBundleIDs: ["us.zoom.xos"],
            displayNames: ["us.zoom.xos": "Zoom"]
        )
        // ImmediateClock: debounce fires instantly, simulating the full
        // 5s elapsing without interruption.
        let detector = makeImmediateDetector(
            catalog: catalog, source: source
        )
        let collector = EventCollector()
        collector.start(from: detector)
        detector.start()

        // Non-self mic user active
        source.emit([makeProcess(
            bundleID: "com.spotify.client",
            isRunningInput: true,
            isRunningOutput: false
        )])
        await collector.settle()

        // Mic user stops -- debounce fires immediately with ImmediateClock
        source.emit([])
        await collector.waitForEvents(count: 1)

        detector.stop()
        await collector.settle()
        collector.cancel()

        #expect(collector.events == [.allMicUsersStopped])
    }

    @Test("flap then real gap emits allMicUsersStopped once on the real gap")
    func flapThenRealGapEmitsOnce() async {
        let source = FakeActivitySource()
        let catalog = FakeMeetingCatalog(
            meetingBundleIDs: ["us.zoom.xos"],
            displayNames: ["us.zoom.xos": "Zoom"]
        )
        // OneShotImmediateClock: the first sleep (the per-app start
        // debounce or the first mic-stop debounce that fires) fires
        // immediately; subsequent ones block. We use this to suppress
        // the flap's mic debounce while letting the real gap's debounce
        // resolve after detector.stop() cleanup.
        //
        // Actually, for this test we need:
        // 1. First dropout: mic debounce starts (blocks with NeverClock)
        //    -> cancelled on reappearance
        // 2. Second dropout: mic debounce starts (fires with ImmediateClock)
        //
        // Use ImmediateClock -- both debounces fire instantly, but the
        // first one is cancelled before it resolves because the
        // reappearance snapshot processes before the debounce task runs.
        let detector = makeImmediateDetector(
            catalog: catalog, source: source
        )
        let collector = EventCollector()
        collector.start(from: detector)
        detector.start()

        // Non-self mic user active
        source.emit([makeProcess(
            bundleID: "com.spotify.client",
            isRunningInput: true,
            isRunningOutput: false
        )])
        await collector.settle()

        // Brief dropout + immediate reappearance (flap)
        // The reappearance snapshot cancels the pending mic debounce
        source.emit([])
        source.emit([makeProcess(
            bundleID: "com.spotify.client",
            isRunningInput: true,
            isRunningOutput: false
        )])
        await collector.settle()

        // Verify no event from the flap
        #expect(collector.events.isEmpty)

        // Real sustained gap -- mic user stops for good
        source.emit([])
        await collector.waitForEvents(count: 1)

        detector.stop()
        await collector.settle()
        collector.cancel()

        // Exactly one allMicUsersStopped from the real gap
        #expect(collector.events == [.allMicUsersStopped])
    }
}

// MARK: - Start flap tolerance tests

@Suite("MeetingDetection — Start Flap Tolerance")
@MainActor
struct StartFlapToleranceTests {
    @Test("flap during start window then steady in-call emits started")
    func flapDuringStartWindowThenSteady() async {
        let source = FakeActivitySource()
        let catalog = FakeMeetingCatalog(
            meetingBundleIDs: ["us.zoom.xos"],
            displayNames: ["us.zoom.xos": "Zoom"]
        )
        // ImmediateClock: debounce fires quickly but not before buffered
        // snapshots are processed (the for-await loop drains the
        // buffered snapshots before yielding to the debounce Task).
        let detector = makeImmediateDetector(
            catalog: catalog, source: source
        )
        let collector = EventCollector()
        collector.start(from: detector)
        detector.start()

        // Sequence: in-call -> flap (not in-call) -> back to in-call
        // Emit all three rapidly so they're buffered before the start
        // debounce Task resolves.
        source.emit([makeProcess(
            bundleID: "us.zoom.xos",
            isRunningInput: true,
            isRunningOutput: true
        )])
        source.emit([makeProcess(
            bundleID: "us.zoom.xos",
            isRunningInput: false,
            isRunningOutput: true
        )])
        source.emit([makeProcess(
            bundleID: "us.zoom.xos",
            isRunningInput: true,
            isRunningOutput: true
        )])
        await collector.waitForEvents(count: 1)

        let zoom = DetectedApp(
            bundleID: "us.zoom.xos", displayName: "Zoom"
        )
        #expect(collector.events == [.started(app: zoom)])

        detector.stop()
        await collector.settle()
        collector.cancel()
    }

    @Test("in-call briefly then genuinely idle at resolve does not emit started")
    func genuinelyIdleAtResolveNoStarted() async {
        let source = FakeActivitySource()
        let catalog = FakeMeetingCatalog(
            meetingBundleIDs: ["us.zoom.xos"],
            displayNames: ["us.zoom.xos": "Zoom"]
        )
        // ImmediateClock so the debounce fires quickly.
        let detector = makeImmediateDetector(
            catalog: catalog, source: source
        )
        let collector = EventCollector()
        collector.start(from: detector)
        detector.start()

        // Brief in-call then immediately idle — debounce should see
        // latestIsInCall == false and not emit .started.
        source.emit([makeProcess(
            bundleID: "us.zoom.xos",
            isRunningInput: true,
            isRunningOutput: true
        )])
        source.emit([makeProcess(
            bundleID: "us.zoom.xos",
            isRunningInput: false,
            isRunningOutput: false
        )])
        await collector.settle()

        // No .started because the app was idle at resolve time
        let startedEvents = collector.events.filter {
            if case .started = $0 { return true }; return false
        }
        #expect(startedEvents.isEmpty)

        detector.stop()
        await collector.settle()
        collector.cancel()
    }
}

// MARK: - Apple system service denylist tests

@Suite("MeetingDetection — Apple System Service Denylist")
@MainActor
struct AppleSystemServiceDenylistTests {
    @Test("com.apple.CoreSpeech using mic does not count as non-self")
    func coreSpeechIgnored() async {
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

        // Only CoreSpeech using mic -- should be ignored (apple non-meeting)
        source.emit([makeProcess(
            bundleID: "com.apple.CoreSpeech",
            isRunningInput: true,
            isRunningOutput: false,
            pid: 100
        )])
        await collector.settle()

        // CoreSpeech stops -- no allMicUsersStopped because it was never
        // counted as a non-self mic user
        source.emit([])
        await collector.settle()

        detector.stop()
        await collector.settle()
        collector.cancel()

        #expect(collector.events.isEmpty)
    }

    @Test("com.apple.FaceTime (catalog meeting app) counts as non-self")
    func faceTimeCountsAsNonSelf() async {
        let source = FakeActivitySource()
        let catalog = FakeMeetingCatalog(
            meetingBundleIDs: ["com.apple.FaceTime"],
            displayNames: ["com.apple.FaceTime": "FaceTime"]
        )
        let detector = makeImmediateDetector(
            catalog: catalog, source: source
        )
        let collector = EventCollector()
        collector.start(from: detector)
        detector.start()

        // FaceTime using mic -- catalog meeting app, should count
        source.emit([makeProcess(
            bundleID: "com.apple.FaceTime",
            isRunningInput: true,
            isRunningOutput: true,
            pid: 200
        )])
        await collector.waitForEvents(count: 1) // .started(FaceTime)

        // FaceTime stops -- should fire allMicUsersStopped
        source.emit([])
        await collector.waitForEvents(count: 2)

        #expect(collector.events.contains(.allMicUsersStopped))

        detector.stop()
        await collector.settle()
        collector.cancel()
    }

    @Test("com.apple.avconferenced (FaceTime helper) counts as non-self, not ignored")
    func avconferencedCountsAsNonSelf() async {
        let source = FakeActivitySource()
        // avconferenced is in the catalog as a helper of FaceTime
        let catalog = FakeMeetingCatalog(
            meetingBundleIDs: ["com.apple.FaceTime", "com.apple.avconferenced"],
            parentMapping: ["com.apple.avconferenced": "com.apple.FaceTime"],
            displayNames: ["com.apple.FaceTime": "FaceTime"]
        )
        let detector = makeImmediateDetector(
            catalog: catalog, source: source
        )
        let collector = EventCollector()
        collector.start(from: detector)
        detector.start()

        // avconferenced using mic -- catalog meeting app, must count as non-self
        source.emit([makeProcess(
            bundleID: "com.apple.avconferenced",
            isRunningInput: true,
            isRunningOutput: true,
            pid: 201
        )])
        await collector.waitForEvents(count: 1) // .started(FaceTime)

        // avconferenced stops -- should fire allMicUsersStopped
        source.emit([])
        await collector.waitForEvents(count: 2)

        #expect(collector.events.contains(.allMicUsersStopped))

        detector.stop()
        await collector.settle()
        collector.cancel()
    }

    @Test("CoreSpeech drop during Bluetooth switch does not false-fire allMicUsersStopped")
    func coreSpeechDropDuringBluetoothSwitch() async {
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

        // Zoom + CoreSpeech both using mic
        source.emit([
            makeProcess(
                bundleID: "us.zoom.xos",
                isRunningInput: true,
                isRunningOutput: true,
                pid: 1
            ),
            makeProcess(
                bundleID: "com.apple.CoreSpeech",
                isRunningInput: true,
                isRunningOutput: false,
                pid: 2
            )
        ])
        await collector.waitForEvents(count: 1) // .started(Zoom)

        // CoreSpeech drops during Bluetooth switch, but Zoom stays.
        // Should NOT cause a >=1->0 transition because Zoom is still
        // a non-self mic user and CoreSpeech was already ignored.
        source.emit([
            makeProcess(
                bundleID: "us.zoom.xos",
                isRunningInput: true,
                isRunningOutput: true,
                pid: 1
            )
        ])
        await collector.settle()

        // Only .started should have fired -- no allMicUsersStopped
        let micStopEvents = collector.events.filter {
            $0 == .allMicUsersStopped
        }
        #expect(micStopEvents.isEmpty)

        detector.stop()
        await collector.settle()
        collector.cancel()
    }

    @Test("non-Apple third-party app still counts as non-self mic user")
    func thirdPartyStillCounts() async {
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

        // Non-catalogued third-party app using mic -- must count
        source.emit([makeProcess(
            bundleID: "com.example.recorder",
            isRunningInput: true,
            isRunningOutput: false,
            pid: 300
        )])
        await collector.settle()

        // Third-party stops -- should fire allMicUsersStopped
        source.emit([])
        await collector.waitForEvents(count: 1)

        #expect(collector.events == [.allMicUsersStopped])

        detector.stop()
        await collector.settle()
        collector.cancel()
    }

    @Test("only CoreSpeech on mic then Zoom joins -- Zoom counted, CoreSpeech still ignored")
    func coreSpeechAloneDoesNotBlockZoomCounting() async {
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

        // Only CoreSpeech -- ignored, no non-self users
        source.emit([makeProcess(
            bundleID: "com.apple.CoreSpeech",
            isRunningInput: true,
            isRunningOutput: false,
            pid: 1
        )])
        await collector.settle()
        #expect(collector.events.isEmpty)

        // Zoom joins -- now there IS a non-self mic user (0->>=1 transition)
        source.emit([
            makeProcess(
                bundleID: "com.apple.CoreSpeech",
                isRunningInput: true,
                isRunningOutput: false,
                pid: 1
            ),
            makeProcess(
                bundleID: "us.zoom.xos",
                isRunningInput: true,
                isRunningOutput: true,
                pid: 2
            )
        ])
        await collector.waitForEvents(count: 1) // .started(Zoom)

        // Zoom stops, only CoreSpeech left -- should fire allMicUsersStopped
        // because the non-self set went from >=1 to 0 (CoreSpeech is ignored)
        source.emit([makeProcess(
            bundleID: "com.apple.CoreSpeech",
            isRunningInput: true,
            isRunningOutput: false,
            pid: 1
        )])
        await collector.waitForEvents(count: 2)

        #expect(collector.events.contains(.allMicUsersStopped))

        detector.stop()
        await collector.settle()
        collector.cancel()
    }
}

// MARK: - Mic-stop debounce self-verify tests

@Suite("MeetingDetection — Mic Stop Self-Verify")
@MainActor
struct MicStopSelfVerifyTests {
    @Test("mic-stop debounce does not emit if non-self mic user reappears at resolve")
    func micStopSuppressedWhenMicReappears() async {
        let source = FakeActivitySource()
        let catalog = FakeMeetingCatalog(
            meetingBundleIDs: ["us.zoom.xos"],
            displayNames: ["us.zoom.xos": "Zoom"]
        )
        // ImmediateClock: the debounce fires quickly. The key is that
        // we re-add a mic user before the debounce resolves. Because
        // the AsyncStream for-await loop processes buffered snapshots
        // before yielding to the debounce Task, the hadNonSelfMicUsers
        // flag is restored to true before resolveMicStopDebounce runs.
        let detector = makeImmediateDetector(
            catalog: catalog, source: source
        )
        let collector = EventCollector()
        collector.start(from: detector)
        detector.start()

        // Non-self mic user active
        source.emit([makeProcess(
            bundleID: "com.spotify.client",
            isRunningInput: true,
            isRunningOutput: false
        )])
        await collector.settle()

        // Mic user drops then reappears in rapid succession.
        // The drop triggers the debounce; the reappearance both cancels
        // the debounce (primary guard) AND sets hadNonSelfMicUsers=true
        // (self-verify guard).
        source.emit([])
        source.emit([makeProcess(
            bundleID: "com.spotify.client",
            isRunningInput: true,
            isRunningOutput: false
        )])
        await collector.settle()

        // No allMicUsersStopped because the mic user is present
        #expect(collector.events.isEmpty)

        detector.stop()
        await collector.settle()
        collector.cancel()
    }
}
