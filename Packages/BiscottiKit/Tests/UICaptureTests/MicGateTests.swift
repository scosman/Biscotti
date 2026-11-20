#if os(macOS)
    import Testing
    @testable import UICapture

    /// Browsers and Ferdium are captured only while on the mic.
    @Suite("UI capture mic gate")
    struct MicGateTests {
        @Test("the app or any of its helpers on the mic counts")
        func helpers() {
            let users: Set = ["org.ferdium.ferdium-app.helper", "com.apple.Safari.helper"]
            #expect(UICaptureController.isUsingMic("org.ferdium.ferdium-app", micUsers: users))
            #expect(!UICaptureController.isUsingMic("com.google.Chrome", micUsers: users))
            #expect(UICaptureController.isUsingMic("com.google.Chrome", micUsers: ["com.google.Chrome"]))
            // A different app sharing a prefix without the dot does not count.
            #expect(!UICaptureController.isUsingMic("com.brave.Browser", micUsers: ["com.brave.BrowserBeta"]))
        }
    }
#endif
