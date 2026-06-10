import Permissions
import Testing

/// A fake `MicAuthorizing` implementation for tests. Scripted status and request results.
///
/// Uses a reference-type backing store so mutations are visible through protocol existentials.
/// All mutable state is `@MainActor`-isolated (matching the test suite) rather than
/// `@unchecked Sendable` — the annotation would overclaim thread-safety.
struct FakeMicAuthorizer: MicAuthorizing, @unchecked Sendable {
    /// Reference-type backing store so mutations survive protocol existential copies.
    /// Confined to `@MainActor` — all test call-sites are `@MainActor`.
    @MainActor
    private final class Backing {
        var status: PermissionState
        var requestResult: Bool
        var requestWasCalled = false

        init(status: PermissionState, requestResult: Bool) {
            self.status = status
            self.requestResult = requestResult
        }
    }

    private let backing: Backing

    @MainActor
    init(status: PermissionState = .notDetermined, requestResult: Bool = true) {
        backing = Backing(status: status, requestResult: requestResult)
    }

    func status() -> PermissionState {
        MainActor.assumeIsolated { backing.status }
    }

    func request() async -> Bool {
        await MainActor.run {
            backing.requestWasCalled = true
            return backing.requestResult
        }
    }

    @MainActor
    var requestWasCalled: Bool {
        backing.requestWasCalled
    }

    /// Mutate the status through the reference-type backing store.
    /// Allows tests to simulate permission changes between calls.
    @MainActor
    func setStatus(_ newStatus: PermissionState) {
        backing.status = newStatus
    }
}

@Suite("Permissions state machine")
struct PermissionsTests {
    @Test("Initial state reflects seam status")
    @MainActor
    func initialState() {
        let fake = FakeMicAuthorizer(status: .notDetermined)
        let permissions = Permissions(mic: fake)
        #expect(permissions.microphone == .notDetermined)
        #expect(permissions.systemAudio == .notDetermined)
    }

    @Test("Initial state authorized when seam reports authorized")
    @MainActor
    func initialStateAuthorized() {
        let fake = FakeMicAuthorizer(status: .authorized)
        let permissions = Permissions(mic: fake)
        #expect(permissions.microphone == .authorized)
    }

    @Test("Refresh re-reads mic status from seam")
    @MainActor
    func refreshReadsFromSeam() {
        // Start notDetermined, verify initial state, then simulate the user
        // granting permission in System Settings and calling refresh().
        let fake = FakeMicAuthorizer(status: .notDetermined)
        let permissions = Permissions(mic: fake)
        #expect(permissions.microphone == .notDetermined)

        // Simulate permission granted externally (e.g. via System Settings).
        fake.setStatus(.authorized)
        permissions.refresh()
        #expect(permissions.microphone == .authorized)
    }

    @Test("requestMicrophone granted transitions to authorized")
    @MainActor
    func requestMicrophoneGranted() async {
        let fake = FakeMicAuthorizer(status: .notDetermined, requestResult: true)
        let permissions = Permissions(mic: fake)
        let result = await permissions.requestMicrophone()
        #expect(result == true)
        #expect(permissions.microphone == .authorized)
    }

    @Test("requestMicrophone denied transitions to denied")
    @MainActor
    func requestMicrophoneDenied() async {
        let fake = FakeMicAuthorizer(status: .notDetermined, requestResult: false)
        let permissions = Permissions(mic: fake)
        let result = await permissions.requestMicrophone()
        #expect(result == false)
        #expect(permissions.microphone == .denied)
    }

    @Test("requestMicrophone skips request when already authorized")
    @MainActor
    func requestMicrophoneSkipsWhenAuthorized() async {
        let fake = FakeMicAuthorizer(status: .authorized, requestResult: false)
        let permissions = Permissions(mic: fake)
        let result = await permissions.requestMicrophone()
        #expect(result == true)
        // The seam's request() should NOT have been called
        #expect(fake.requestWasCalled == false)
    }

    @Test("requestMicrophone returns false when already denied")
    @MainActor
    func requestMicrophoneReturnsFalseWhenDenied() async {
        let fake = FakeMicAuthorizer(status: .denied, requestResult: true)
        let permissions = Permissions(mic: fake)
        let result = await permissions.requestMicrophone()
        #expect(result == false)
        #expect(permissions.microphone == .denied)
        #expect(fake.requestWasCalled == false)
    }

    @Test("noteSystemAudio updates systemAudio state")
    @MainActor
    func noteSystemAudio() {
        let fake = FakeMicAuthorizer(status: .authorized)
        let permissions = Permissions(mic: fake)
        #expect(permissions.systemAudio == .notDetermined)

        permissions.noteSystemAudio(.denied)
        #expect(permissions.systemAudio == .denied)

        permissions.noteSystemAudio(.authorized)
        #expect(permissions.systemAudio == .authorized)
    }

    @Test("settingsURL for microphone returns correct URL")
    @MainActor
    func settingsURLMicrophone() {
        let fake = FakeMicAuthorizer()
        let permissions = Permissions(mic: fake)
        let url = permissions.settingsURL(for: .microphone)
        #expect(url.absoluteString.contains("Privacy_Microphone"))
    }

    @Test("settingsURL for systemAudio returns correct URL")
    @MainActor
    func settingsURLSystemAudio() {
        let fake = FakeMicAuthorizer()
        let permissions = Permissions(mic: fake)
        let url = permissions.settingsURL(for: .systemAudio)
        #expect(url.absoluteString.contains("Privacy_ScreenCapture"))
    }
}
