import Testing
@testable import SettingsUI

@Suite("SettingsView -- layout")
struct SettingsLayoutTests {
    /// sectionTitles drives the rendered Section headers via indexed lookup
    /// (e.g. Section(Self.sectionTitles[0])), so this assertion verifies
    /// the titles AND their order as they appear on screen. The physical
    /// section ordering in `body` (which computed property appears first)
    /// is verified in the Phase 12 manual pass.
    @Test("section titles match spec order: General, Permissions, Notifications, AI, Calendars")
    func sectionTitlesMatchSpec() {
        let expected = [
            "General",
            "Permissions",
            "Notifications",
            "AI Enhancements",
            "Calendars"
        ]
        #expect(SettingsView.sectionTitles == expected)
    }

    /// aiEnhancementsHeaderCaption is used directly in the header HStack,
    /// so this assertion verifies the rendered caption text.
    @Test("AI Enhancements header caption renders correct text")
    func aiEnhancementsHeaderCaption() {
        #expect(
            SettingsView.aiEnhancementsHeaderCaption
                == "AI runs locally on your Mac."
        )
    }
}
