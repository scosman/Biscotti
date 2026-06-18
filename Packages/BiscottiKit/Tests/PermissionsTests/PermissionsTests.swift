import BiscottiTestSupport
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
        #expect(permissions.systemAudio == .notRequested)
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
    func refreshReadsFromSeam() async {
        // Start notDetermined, verify initial state, then simulate the user
        // granting permission in System Settings and calling refresh().
        let fake = FakeMicAuthorizer(status: .notDetermined)
        let permissions = Permissions(mic: fake)
        #expect(permissions.microphone == .notDetermined)

        // Simulate permission granted externally (e.g. via System Settings).
        fake.setStatus(.authorized)
        await permissions.refresh()
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

    @Test("setSystemAudio updates state and persists")
    @MainActor
    func setSystemAudioUpdatesAndPersists() {
        let fake = FakeMicAuthorizer(status: .authorized)
        let store = InMemorySystemAudioPermissionStore()
        let permissions = Permissions(mic: fake, systemAudioStore: store)
        #expect(permissions.systemAudio == .notRequested)

        permissions.setSystemAudio(.requestedNotVerified)
        #expect(permissions.systemAudio == .requestedNotVerified)
        #expect(store.load() == .requestedNotVerified)

        permissions.setSystemAudio(.approved)
        #expect(permissions.systemAudio == .approved)
        #expect(store.load() == .approved)
    }

    @Test("init restores system audio state from store")
    @MainActor
    func initRestoresSystemAudioFromStore() {
        let store = InMemorySystemAudioPermissionStore()
        store.save(.approved)

        let fake = FakeMicAuthorizer(status: .authorized)
        let permissions = Permissions(mic: fake, systemAudioStore: store)
        #expect(permissions.systemAudio == .approved)
    }

    @Test("setSystemAudio transition: requestedNotVerified -> approved")
    @MainActor
    func systemAudioTransitionToApproved() {
        let store = InMemorySystemAudioPermissionStore()
        let permissions = Permissions(
            mic: FakeMicAuthorizer(status: .authorized),
            systemAudioStore: store
        )

        // Simulate probe start
        permissions.setSystemAudio(.requestedNotVerified)
        #expect(permissions.systemAudio == .requestedNotVerified)

        // Simulate tone observed
        permissions.setSystemAudio(.approved)
        #expect(permissions.systemAudio == .approved)
        #expect(store.load() == .approved)
    }

    @Test("setSystemAudio transition: timeout stays requestedNotVerified")
    @MainActor
    func systemAudioTransitionTimeoutStaysRequestedNotVerified() {
        let store = InMemorySystemAudioPermissionStore()
        let permissions = Permissions(
            mic: FakeMicAuthorizer(status: .authorized),
            systemAudioStore: store
        )

        permissions.setSystemAudio(.requestedNotVerified)
        #expect(permissions.systemAudio == .requestedNotVerified)

        // Simulate timeout: state remains requestedNotVerified
        permissions.setSystemAudio(.requestedNotVerified)
        #expect(permissions.systemAudio == .requestedNotVerified)
        #expect(store.load() == .requestedNotVerified)
    }

    @Test("displayText returns expected strings")
    func displayTextValues() {
        #expect(SystemAudioPermissionState.notRequested.displayText == "Not Requested")
        #expect(SystemAudioPermissionState.requestedNotVerified.displayText == "Not approved")
        #expect(SystemAudioPermissionState.approved.displayText == "Granted")
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

    @Test("settingsURL for calendar returns correct URL")
    @MainActor
    func settingsURLCalendar() {
        let fake = FakeMicAuthorizer()
        let permissions = Permissions(mic: fake)
        let url = permissions.settingsURL(for: .calendar)
        #expect(url.absoluteString.contains("Privacy_Calendars"))
    }

    @Test("settingsURL for notifications returns correct URL")
    @MainActor
    func settingsURLNotifications() {
        let fake = FakeMicAuthorizer()
        let permissions = Permissions(mic: fake)
        let url = permissions.settingsURL(for: .notifications)
        #expect(url.absoluteString.contains("Notifications-Settings"))
    }
}

// MARK: - Calendar/Notification Fakes

struct FakeCalendarAuthorizer: CalendarAuthorizing, @unchecked Sendable {
    @MainActor
    private final class Backing {
        var status: PermissionState
        var requestResult: PermissionState

        init(status: PermissionState, requestResult: PermissionState) {
            self.status = status
            self.requestResult = requestResult
        }
    }

    private let backing: Backing

    @MainActor
    init(status: PermissionState = .notDetermined, requestResult: PermissionState = .authorized) {
        backing = Backing(status: status, requestResult: requestResult)
    }

    func status() -> PermissionState {
        MainActor.assumeIsolated { backing.status }
    }

    func request() async -> PermissionState {
        await MainActor.run { backing.requestResult }
    }

    @MainActor
    func setStatus(_ newStatus: PermissionState) {
        backing.status = newStatus
    }
}

struct FakeNotificationAuthorizer: NotificationAuthorizing, @unchecked Sendable {
    @MainActor
    private final class Backing {
        var status: PermissionState
        var requestResult: Bool

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

    func status() async -> PermissionState {
        await MainActor.run { backing.status }
    }

    func request() async -> Bool {
        await MainActor.run { backing.requestResult }
    }

    @MainActor
    func setStatus(_ newStatus: PermissionState) {
        backing.status = newStatus
    }
}

// MARK: - Calendar permission tests

@Suite("Permissions -- calendar")
struct PermissionsCalendarTests {
    @Test("Initial calendar state reflects seam status")
    @MainActor
    func initialCalendarState() {
        let mic = FakeMicAuthorizer()
        let cal = FakeCalendarAuthorizer(status: .authorized)
        let permissions = Permissions(mic: mic, cal: cal)
        #expect(permissions.calendar == .authorized)
    }

    @Test("Calendar state is notDetermined when no seam provided")
    @MainActor
    func calendarNoSeam() {
        let mic = FakeMicAuthorizer()
        let permissions = Permissions(mic: mic)
        #expect(permissions.calendar == .notDetermined)
    }

    @Test("noteCalendar updates state")
    @MainActor
    func noteCalendar() {
        let mic = FakeMicAuthorizer()
        let permissions = Permissions(mic: mic)
        #expect(permissions.calendar == .notDetermined)

        permissions.noteCalendar(.authorized)
        #expect(permissions.calendar == .authorized)

        permissions.noteCalendar(.denied)
        #expect(permissions.calendar == .denied)
    }

    @Test("requestCalendar returns authorized on grant")
    @MainActor
    func requestCalendarGranted() async {
        let mic = FakeMicAuthorizer()
        let cal = FakeCalendarAuthorizer(status: .notDetermined, requestResult: .authorized)
        let permissions = Permissions(mic: mic, cal: cal)

        let result = await permissions.requestCalendar()
        #expect(result == .authorized)
        #expect(permissions.calendar == .authorized)
    }

    @Test("requestCalendar returns denied when denied")
    @MainActor
    func requestCalendarDenied() async {
        let mic = FakeMicAuthorizer()
        let cal = FakeCalendarAuthorizer(status: .notDetermined, requestResult: .denied)
        let permissions = Permissions(mic: mic, cal: cal)

        let result = await permissions.requestCalendar()
        #expect(result == .denied)
        #expect(permissions.calendar == .denied)
    }

    @Test("requestCalendar with no seam returns current state")
    @MainActor
    func requestCalendarNoSeam() async {
        let mic = FakeMicAuthorizer()
        let permissions = Permissions(mic: mic)

        let result = await permissions.requestCalendar()
        #expect(result == .notDetermined)
    }

    @Test("Refresh re-reads calendar status from seam")
    @MainActor
    func refreshReadsCalendar() async {
        let mic = FakeMicAuthorizer()
        let cal = FakeCalendarAuthorizer(status: .notDetermined)
        let permissions = Permissions(mic: mic, cal: cal)
        #expect(permissions.calendar == .notDetermined)

        cal.setStatus(.authorized)
        await permissions.refresh()
        #expect(permissions.calendar == .authorized)
    }
}

// MARK: - Notification permission tests

@Suite("Permissions -- notifications")
struct PermissionsNotificationTests {
    @Test("Initial notifications state is notDetermined")
    @MainActor
    func initialNotificationsState() {
        let mic = FakeMicAuthorizer()
        let notif = FakeNotificationAuthorizer(status: .authorized)
        // notifications status is async so not read at init; starts notDetermined
        let permissions = Permissions(mic: mic, notif: notif)
        #expect(permissions.notifications == .notDetermined)
    }

    @Test("noteNotifications updates state")
    @MainActor
    func noteNotifications() {
        let mic = FakeMicAuthorizer()
        let permissions = Permissions(mic: mic)
        #expect(permissions.notifications == .notDetermined)

        permissions.noteNotifications(.authorized)
        #expect(permissions.notifications == .authorized)

        permissions.noteNotifications(.denied)
        #expect(permissions.notifications == .denied)
    }

    @Test("requestNotifications returns true on grant")
    @MainActor
    func requestNotificationsGranted() async {
        let mic = FakeMicAuthorizer()
        let notif = FakeNotificationAuthorizer(requestResult: true)
        let permissions = Permissions(mic: mic, notif: notif)

        let result = await permissions.requestNotifications()
        #expect(result == true)
        #expect(permissions.notifications == .authorized)
    }

    @Test("requestNotifications returns false on denial")
    @MainActor
    func requestNotificationsDenied() async {
        let mic = FakeMicAuthorizer()
        let notif = FakeNotificationAuthorizer(requestResult: false)
        let permissions = Permissions(mic: mic, notif: notif)

        let result = await permissions.requestNotifications()
        #expect(result == false)
        #expect(permissions.notifications == .denied)
    }

    @Test("requestNotifications with no seam returns false")
    @MainActor
    func requestNotificationsNoSeam() async {
        let mic = FakeMicAuthorizer()
        let permissions = Permissions(mic: mic)

        let result = await permissions.requestNotifications()
        #expect(result == false)
    }

    @Test("Refresh re-reads notifications status from seam")
    @MainActor
    func refreshReadsNotifications() async {
        let mic = FakeMicAuthorizer()
        let notif = FakeNotificationAuthorizer(status: .notDetermined)
        let permissions = Permissions(mic: mic, notif: notif)

        notif.setStatus(.authorized)
        await permissions.refresh()
        #expect(permissions.notifications == .authorized)
    }
}
