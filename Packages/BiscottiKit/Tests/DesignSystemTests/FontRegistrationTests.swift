import AppKit
import DesignSystem
import Testing

@Suite("FontRegistration")
struct FontRegistrationTests {
    @Test("JetBrains Mono Regular is available after registration")
    func jetBrainsMonoRegularRegistered() {
        FontRegistration.ensure()
        let font = NSFont(name: "JetBrainsMono-Regular", size: 12)
        #expect(font != nil, "JetBrainsMono-Regular should be registered")
    }

    @Test("JetBrains Mono Medium is available after registration")
    func jetBrainsMonoMediumRegistered() {
        FontRegistration.ensure()
        let font = NSFont(name: "JetBrainsMono-Medium", size: 12)
        #expect(font != nil, "JetBrainsMono-Medium should be registered")
    }

    @Test("Newsreader Display Medium is available after registration")
    func newsreaderDisplayMediumRegistered() {
        FontRegistration.ensure()
        let font = NSFont(name: "NewsreaderDisplay-Medium", size: 12)
        #expect(font != nil, "NewsreaderDisplay-Medium should be registered")
    }

    @Test("All registered names resolve to non-nil NSFont")
    func allRegisteredNamesResolve() {
        FontRegistration.ensure()
        for name in FontRegistration.registeredNames {
            let font = NSFont(name: name, size: 12)
            #expect(font != nil, "\(name) should be registered and resolvable")
        }
    }

    @Test("ensure() is idempotent -- calling twice does not crash")
    func ensureIdempotent() {
        FontRegistration.ensure()
        FontRegistration.ensure()
        // If we got here, no crash or error from double registration.
        let font = NSFont(name: "JetBrainsMono-Regular", size: 12)
        #expect(font != nil)
    }
}
