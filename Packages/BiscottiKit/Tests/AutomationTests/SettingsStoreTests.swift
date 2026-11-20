import Foundation
import Testing
@testable import Automation

@Suite("AutomationSettings")
@MainActor
struct AutomationSettingsTests {
    @Test("defaults are conservative")
    func defaults() {
        let settings = AutomationSettings()
        #expect(settings.recordingMode == .ask)
        #expect(settings.autoRecordInBrowsers == false)
        #expect(settings.stopOnScreenLock == true)
        #expect(settings.captureMeetingUI == true)
        #expect(settings.retention == RetentionPolicy())
        #expect(settings.exportTargets.isEmpty)
    }

    @Test("settings persist across store instances")
    func persistence() throws {
        let suite = "automation-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let target = ExportTarget(name: "Repo", kind: .gitRepository, path: "/tmp/r", subfolder: "m", pushAfterCommit: true)
        let first = AutomationSettingsStore(defaults: defaults)
        first.update {
            $0.recordingMode = .automatic
            $0.stopOnScreenLock = false
            $0.retention.audioRetentionDays = 7
            $0.exportTargets = [target]
        }

        let second = AutomationSettingsStore(defaults: defaults)
        #expect(second.settings.recordingMode == .automatic)
        #expect(second.settings.stopOnScreenLock == false)
        #expect(second.settings.retention.audioRetentionDays == 7)
        #expect(second.settings.exportTargets == [target])
    }

    @Test("unknown or missing keys fall back to defaults instead of wiping settings")
    func tolerantDecoding() throws {
        let json = #"{"recordingMode":"someFutureMode","stopOnScreenLock":false}"#
        let decoded = try JSONDecoder().decode(AutomationSettings.self, from: Data(json.utf8))
        #expect(decoded.recordingMode == .ask)
        #expect(decoded.stopOnScreenLock == false)
        #expect(decoded.exportTargets.isEmpty)
    }

    @Test("export ledger tracks, forgets and persists")
    func ledger() throws {
        let suite = "automation-ledger-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = UUID()
        let second = UUID()
        let store = AutomationSettingsStore(defaults: defaults)
        store.update { $0.exportTargets = [ExportTarget(name: "Notes", kind: .folder, path: "/tmp/notes")] }
        store.markExported(first)
        store.markExported(second)
        #expect(store.isExported(first))

        store.forgetExports([first])
        #expect(!store.isExported(first))

        let reloaded = AutomationSettingsStore(defaults: defaults)
        #expect(reloaded.isExported(second))
        #expect(!reloaded.isExported(first))

        reloaded.forgetAllExports()
        #expect(!reloaded.isExported(second))
    }

    @Test("moving a target's destination resets what it received; renaming doesn't")
    func movedTargetResetsExported() throws {
        let suite = "automation-ledger-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AutomationSettingsStore(defaults: defaults)
        var notes = ExportTarget(name: "Notes", kind: .folder, path: "/tmp/notes")
        store.update { $0.exportTargets = [notes] }
        let meeting = UUID()
        store.markExported(meeting, targets: [notes.id])

        notes.name = "Meeting notes"
        store.update { $0.exportTargets = [notes] }
        #expect(store.isExported(meeting))

        notes.path = "/tmp/elsewhere"
        store.update { $0.exportTargets = [notes] }
        #expect(!store.isExported(meeting))
        store.markExported(meeting, targets: [notes.id])
        #expect(store.isExported(meeting))
    }

    @Test("a target added later hasn't received older meetings")
    func newTargetResetsExported() throws {
        let suite = "automation-ledger-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AutomationSettingsStore(defaults: defaults)
        let notes = ExportTarget(name: "Notes", kind: .folder, path: "/tmp/notes")
        let archive = ExportTarget(name: "Archive", kind: .folder, path: "/tmp/archive")
        store.update { $0.exportTargets = [notes] }
        let meeting = UUID()
        store.markExported(meeting, targets: [notes.id])
        #expect(store.isExported(meeting))

        store.update { $0.exportTargets = [notes, archive] }
        #expect(!store.isExported(meeting))
        store.markExported(meeting, targets: [archive.id])
        #expect(store.isExported(meeting))
    }

    @Test("the old ledger converts to every target enabled at the time")
    func legacyLedgerMigrates() throws {
        let suite = "automation-ledger-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let notes = ExportTarget(name: "Notes", kind: .folder, path: "/tmp/notes")
        let meeting = UUID()
        try defaults.set(JSONEncoder().encode(AutomationSettings(exportTargets: [notes])), forKey: "biscotti.automation.settings.v1")
        defaults.set([meeting.uuidString: 1_700_000_000.0], forKey: "biscotti.automation.exportLedger.v1")

        let store = AutomationSettingsStore(defaults: defaults)
        #expect(store.isExported(meeting))
        #expect(defaults.object(forKey: "biscotti.automation.exportLedger.v1") == nil)
    }

    @Test("ephemeral stores never capture meeting UI; saved settings without the key default to on")
    func captureMeetingUIDefaults() throws {
        #expect(AutomationSettingsStore.ephemeral().settings.captureMeetingUI == false)
        let older = try JSONDecoder().decode(AutomationSettings.self, from: Data(#"{"recordingMode":"automatic"}"#.utf8))
        #expect(older.captureMeetingUI == true)
    }

    @Test("ephemeral stores are isolated")
    func ephemeralIsolation() {
        let one = AutomationSettingsStore.ephemeral()
        one.update { $0.recordingMode = .paused }
        let two = AutomationSettingsStore.ephemeral()
        #expect(two.settings.recordingMode == .ask)
    }
}

/// Speaker naming and capture settings.
struct SpeakerSettingsTests {
    @Test func newSettingsDefaultSensiblyWhenMissingFromOldSaves() throws {
        let old = Data(#"{"recordingMode":"automatic","captureMeetingUI":true}"#.utf8)
        let settings = try JSONDecoder().decode(AutomationSettings.self, from: old)
        #expect(settings.nameSpeakers)
        #expect(settings.transcriptName.isEmpty)
        #expect(settings.captureExcludedApps.isEmpty)
        #expect(settings.captureKeepDays == 30)
    }

    @Test func newSettingsRoundTrip() throws {
        var settings = AutomationSettings()
        settings.nameSpeakers = false
        settings.transcriptName = "Sam Carter"
        settings.captureExcludedApps = [BrowserApps.groupID]
        settings.captureKeepDays = 7
        let decoded = try JSONDecoder().decode(AutomationSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
    }

    @MainActor
    @Test func ephemeralStoreNeverNamesSpeakersOrRunsLaunchChecks() {
        let store = AutomationSettingsStore.ephemeral()
        #expect(store.settings.nameSpeakers == false)
        #expect(store.isLive == false)
    }
}
