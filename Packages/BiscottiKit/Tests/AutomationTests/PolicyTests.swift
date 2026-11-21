import Foundation
import Testing
@testable import Automation

@Suite("DetectionPolicy")
struct DetectionPolicyTests {
    @Test("paused ignores every detection")
    func pausedIgnores() {
        for bundle in ["us.zoom.xos", "com.google.Chrome"] {
            let response = DetectionPolicy.response(
                mode: .paused, bundleID: bundle, autoRecordInBrowsers: true, monitorForMeetings: true
            )
            #expect(response == .ignore)
        }
    }

    @Test("ask offers when monitoring is on and ignores when off")
    func askFollowsMonitorToggle() {
        #expect(DetectionPolicy.response(
            mode: .ask, bundleID: "us.zoom.xos", autoRecordInBrowsers: false, monitorForMeetings: true
        ) == .offerToRecord)
        #expect(DetectionPolicy.response(
            mode: .ask, bundleID: "us.zoom.xos", autoRecordInBrowsers: false, monitorForMeetings: false
        ) == .ignore)
    }

    @Test("automatic records native meeting apps even with monitoring off")
    func automaticRecordsNativeApps() {
        for bundle in ["us.zoom.xos", "com.microsoft.teams2", "com.cisco.webexmeetingsapp"] {
            #expect(DetectionPolicy.response(
                mode: .automatic, bundleID: bundle, autoRecordInBrowsers: false, monitorForMeetings: false
            ) == .recordAutomatically)
        }
    }

    @Test("automatic falls back to an offer for browsers unless browsers are allowed")
    func automaticBrowserGate() {
        for bundle in ["com.google.Chrome", "com.microsoft.edgemac", "org.mozilla.firefox", "com.apple.Safari"] {
            #expect(DetectionPolicy.response(
                mode: .automatic, bundleID: bundle, autoRecordInBrowsers: false, monitorForMeetings: true
            ) == .offerToRecord)
            #expect(DetectionPolicy.response(
                mode: .automatic, bundleID: bundle, autoRecordInBrowsers: false, monitorForMeetings: false
            ) == .ignore)
            #expect(DetectionPolicy.response(
                mode: .automatic, bundleID: bundle, autoRecordInBrowsers: true, monitorForMeetings: false
            ) == .recordAutomatically)
        }
    }
}

@Suite("RetentionPlanner")
struct RetentionPlannerTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func candidate(
        daysAgo: Double, transcript: Bool = true, audio: Bool = true, exported: Bool = true
    ) -> RetentionCandidate {
        RetentionCandidate(
            id: UUID(), date: now.addingTimeInterval(-daysAgo * 86400),
            hasTranscript: transcript, hasAudio: audio, isExported: exported
        )
    }

    @Test("default policy deletes nothing")
    func defaultKeepsEverything() {
        let plan = RetentionPlanner.plan(
            candidates: [candidate(daysAgo: 1000)], policy: RetentionPolicy(),
            now: now, protected: [], hasEnabledExportTargets: true
        )
        #expect(plan.isEmpty)
    }

    @Test("audio is deleted after the window, only once a transcript exists")
    func audioWindow() {
        let old = candidate(daysAgo: 8)
        let young = candidate(daysAgo: 6)
        let noTranscript = candidate(daysAgo: 30, transcript: false)
        let noAudio = candidate(daysAgo: 30, audio: false)
        let plan = RetentionPlanner.plan(
            candidates: [old, young, noTranscript, noAudio],
            policy: RetentionPolicy(audioRetentionDays: 7),
            now: now, protected: [], hasEnabledExportTargets: false
        )
        #expect(plan.audioToDelete == [old.id])
        #expect(plan.meetingsToDelete.isEmpty)
    }

    @Test("zero-day audio retention deletes as soon as transcribed")
    func audioImmediately() {
        let fresh = candidate(daysAgo: 0)
        let pending = candidate(daysAgo: 0, transcript: false)
        let plan = RetentionPlanner.plan(
            candidates: [fresh, pending], policy: RetentionPolicy(audioRetentionDays: 0),
            now: now, protected: [], hasEnabledExportTargets: false
        )
        #expect(plan.audioToDelete == [fresh.id])
    }

    @Test("meetings are deleted only when exported, when export is required")
    func meetingRequiresExport() {
        let exported = candidate(daysAgo: 40, exported: true)
        let notExported = candidate(daysAgo: 40, exported: false)
        let policy = RetentionPolicy(audioRetentionDays: 7, meetingRetentionDays: 30)
        let plan = RetentionPlanner.plan(
            candidates: [exported, notExported], policy: policy,
            now: now, protected: [], hasEnabledExportTargets: true
        )
        #expect(plan.meetingsToDelete == [exported.id])
        // The unexported one still loses its audio.
        #expect(plan.audioToDelete == [notExported.id])
    }

    @Test("with export required and no targets, no meeting is deleted")
    func noTargetsNoDelete() {
        let plan = RetentionPlanner.plan(
            candidates: [candidate(daysAgo: 400)],
            policy: RetentionPolicy(meetingRetentionDays: 30),
            now: now, protected: [], hasEnabledExportTargets: false
        )
        #expect(plan.meetingsToDelete.isEmpty)
    }

    @Test("export requirement can be turned off")
    func exportNotRequired() {
        let item = candidate(daysAgo: 31, exported: false)
        let plan = RetentionPlanner.plan(
            candidates: [item],
            policy: RetentionPolicy(meetingRetentionDays: 30, requireExportBeforeDelete: false),
            now: now, protected: [], hasEnabledExportTargets: false
        )
        #expect(plan.meetingsToDelete == [item.id])
    }

    @Test("protected meetings are never touched")
    func protectedSkipped() {
        let item = candidate(daysAgo: 400)
        let plan = RetentionPlanner.plan(
            candidates: [item],
            policy: RetentionPolicy(audioRetentionDays: 0, meetingRetentionDays: 30, requireExportBeforeDelete: false),
            now: now, protected: [item.id], hasEnabledExportTargets: true
        )
        #expect(plan.isEmpty)
    }

    @Test("labels")
    func labels() {
        #expect(RetentionPolicy.label(forDays: nil) == "Keep forever")
        #expect(RetentionPolicy.label(forDays: 0) == "After transcription")
        #expect(RetentionPolicy.label(forDays: 1) == "1 day")
        #expect(RetentionPolicy.label(forDays: 30) == "30 days")
    }
}

@Suite("ExportTarget")
struct ExportTargetTests {
    @Test("subfolder cleaning blocks traversal and trims slashes")
    func cleanSubfolder() {
        #expect(ExportTarget.cleanSubfolder("/meetings/") == "meetings")
        #expect(ExportTarget.cleanSubfolder("../../etc") == "etc")
        #expect(ExportTarget.cleanSubfolder("notes/./2026/../x") == "notes/2026/x")
        #expect(ExportTarget.cleanSubfolder("  ") == "")
    }

    @Test("output directory and pathspec")
    func directories() {
        let folder = ExportTarget(name: "F", kind: .folder, path: "/tmp/out", subfolder: "ignored")
        #expect(folder.outputDirectory.path == "/tmp/out")
        let repo = ExportTarget(name: "G", kind: .gitRepository, path: "/tmp/repo", subfolder: "meetings/2026")
        #expect(repo.outputDirectory.path == "/tmp/repo/meetings/2026")
        #expect(repo.gitPathspec == "meetings/2026")
        let rootRepo = ExportTarget(name: "R", kind: .gitRepository, path: "/tmp/repo")
        #expect(rootRepo.gitPathspec == ".")
        #expect(rootRepo.outputDirectory.path == "/tmp/repo")
    }
}
