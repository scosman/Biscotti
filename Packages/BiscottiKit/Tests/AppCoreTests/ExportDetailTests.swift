import Automation
import Testing
@testable import AppCore

/// The words shown for what an export did.
@MainActor
struct ExportDetailTests {
    @Test func describesReplaceNewKeepAndFailure() {
        #expect(AppCore.exportDetail(failures: [], replaced: true, kept: [], targets: ["Transcriptions"])
            == "Replaced the existing file in Transcriptions.")
        #expect(AppCore.exportDetail(failures: [], replaced: false, kept: [], targets: ["Transcriptions"])
            == "Wrote a new file to Transcriptions.")
        #expect(AppCore.exportDetail(failures: [], replaced: false, kept: ["Old (before 2026-11-18 1530).md"], targets: ["A", "B"])
            == "Kept the old file as \u{201C}Old (before 2026-11-18 1530).md\u{201D} and wrote the new one to A, B.")
        #expect(AppCore.exportDetail(failures: ["Repo: git commit failed"], replaced: true, kept: [], targets: ["Repo"])
            == "Failed: Repo: git commit failed")
    }

    @Test func reTranscribeSettingPicksTheChoiceWithoutAsking() {
        #expect(ReTranscribeExportBehavior.ask.automaticChoice == nil)
        #expect(ReTranscribeExportBehavior.replace.automaticChoice == .replace)
        #expect(ReTranscribeExportBehavior.keepOld.automaticChoice == .keepBoth)
        #expect(ReTranscribeExportBehavior.skip.automaticChoice == .skip)
    }
}
