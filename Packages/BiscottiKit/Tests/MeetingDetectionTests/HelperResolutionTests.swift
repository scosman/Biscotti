import AudioCapture
import MeetingCatalog
import MeetingDetection
import Testing

@Suite("MeetingDetection — Helper Resolution")
@MainActor
struct HelperResolutionTests {
    @Test("Helper WebKit.GPU maps to Safari")
    func helperMapsToParent() async {
        let source = FakeActivitySource()
        let catalog = FakeMeetingCatalog(
            meetingBundleIDs: [
                "com.apple.WebKit.GPU", "com.apple.Safari"
            ],
            parentMapping: [
                "com.apple.WebKit.GPU": "com.apple.Safari"
            ],
            displayNames: ["com.apple.Safari": "Safari"]
        )
        let detector = makeImmediateDetector(
            catalog: catalog, source: source
        )
        let collector = EventCollector()
        collector.start(from: detector)
        detector.start()

        source.emit([makeProcess(
            bundleID: "com.apple.WebKit.GPU",
            isRunningInput: true,
            isRunningOutput: true
        )])
        await collector.waitForEvents(count: 1)

        #expect(collector.events == [
            .started(app: DetectedApp(
                bundleID: "com.apple.Safari",
                displayName: "Safari"
            ))
        ])
        detector.stop()
        collector.cancel()
    }

    @Test("avconferenced maps to FaceTime")
    func avconferencedToFaceTime() async {
        let source = FakeActivitySource()
        let catalog = FakeMeetingCatalog(
            meetingBundleIDs: [
                "com.apple.avconferenced", "com.apple.FaceTime"
            ],
            parentMapping: [
                "com.apple.avconferenced": "com.apple.FaceTime"
            ],
            displayNames: ["com.apple.FaceTime": "FaceTime"]
        )
        let detector = makeImmediateDetector(
            catalog: catalog, source: source
        )
        let collector = EventCollector()
        collector.start(from: detector)
        detector.start()

        source.emit([makeProcess(
            bundleID: "com.apple.avconferenced",
            isRunningInput: true,
            isRunningOutput: true
        )])
        await collector.waitForEvents(count: 1)

        #expect(collector.events[0] == .started(
            app: DetectedApp(
                bundleID: "com.apple.FaceTime",
                displayName: "FaceTime"
            )
        ))
        detector.stop()
        collector.cancel()
    }

    @Test("Slack helper maps to Slack")
    func slackHelperToSlack() async {
        let source = FakeActivitySource()
        let catalog = FakeMeetingCatalog(
            meetingBundleIDs: [
                "com.tinyspeck.slackmacgap.helper",
                "com.tinyspeck.slackmacgap"
            ],
            parentMapping: [
                "com.tinyspeck.slackmacgap.helper":
                    "com.tinyspeck.slackmacgap"
            ],
            displayNames: ["com.tinyspeck.slackmacgap": "Slack"]
        )
        let detector = makeImmediateDetector(
            catalog: catalog, source: source
        )
        let collector = EventCollector()
        collector.start(from: detector)
        detector.start()

        source.emit([makeProcess(
            bundleID: "com.tinyspeck.slackmacgap.helper",
            isRunningInput: true,
            isRunningOutput: true
        )])
        await collector.waitForEvents(count: 1)

        #expect(collector.events[0] == .started(
            app: DetectedApp(
                bundleID: "com.tinyspeck.slackmacgap",
                displayName: "Slack"
            )
        ))
        detector.stop()
        collector.cancel()
    }

    @Test("Multiple helpers same parent merged via OR")
    func multipleHelpersMerged() async {
        let source = FakeActivitySource()
        let catalog = FakeMeetingCatalog(
            meetingBundleIDs: [
                "com.apple.FaceTime",
                "com.apple.avconferenced"
            ],
            parentMapping: [
                "com.apple.avconferenced": "com.apple.FaceTime"
            ],
            displayNames: ["com.apple.FaceTime": "FaceTime"]
        )
        let detector = makeImmediateDetector(
            catalog: catalog, source: source
        )
        let collector = EventCollector()
        collector.start(from: detector)
        detector.start()

        // avconferenced supplies the mic; OR-merge across the shared
        // parent makes the merged mic flag true.
        source.emit([
            makeProcess(
                bundleID: "com.apple.FaceTime",
                isRunningInput: false,
                isRunningOutput: true,
                pid: 1
            ),
            makeProcess(
                bundleID: "com.apple.avconferenced",
                isRunningInput: true,
                isRunningOutput: false,
                pid: 2
            )
        ])
        await collector.waitForEvents(count: 1)

        #expect(collector.events == [
            .started(app: DetectedApp(
                bundleID: "com.apple.FaceTime",
                displayName: "FaceTime"
            ))
        ])
        detector.stop()
        collector.cancel()
    }
}
