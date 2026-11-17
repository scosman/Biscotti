import Testing
@testable import DesignSystem

@Suite("ExportIcons")
struct ExportIconTests {
    @Test("All three icons load successfully", arguments: ExportIcons.Kind.allCases)
    @MainActor
    func iconLoads(kind: ExportIcons.Kind) {
        let image = ExportIcons.image(kind)
        #expect(image.size.width > 0)
        #expect(image.size.height > 0)
    }

    @Test("All icons are template images", arguments: ExportIcons.Kind.allCases)
    @MainActor
    func iconIsTemplate(kind: ExportIcons.Kind) {
        let image = ExportIcons.image(kind)
        #expect(image.isTemplate)
    }

    @Test("Icons are cached -- same instance returned")
    @MainActor
    func iconsCached() {
        let first = ExportIcons.image(.obsidian)
        let second = ExportIcons.image(.obsidian)
        #expect(first === second)
    }
}
