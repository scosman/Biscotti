import Notifications
import Testing
import UserNotifications

@Suite("currentAlertStyle mapping")
@MainActor
struct AlertStyleTests {
    @Test("maps UNAlertStyle.banner to .banner")
    func mapsBanner() async {
        let fake = FakeNotificationCenter()
        fake.scriptedAlertStyle = .banner
        let service = NotificationService(provider: fake)

        let style = await service.currentAlertStyle()
        #expect(style == .banner)
    }

    @Test("maps UNAlertStyle.alert to .alert")
    func mapsAlert() async {
        let fake = FakeNotificationCenter()
        fake.scriptedAlertStyle = .alert
        let service = NotificationService(provider: fake)

        let style = await service.currentAlertStyle()
        #expect(style == .alert)
    }

    @Test("maps UNAlertStyle.none to .none")
    func mapsNone() async {
        let fake = FakeNotificationCenter()
        fake.scriptedAlertStyle = .none
        let service = NotificationService(provider: fake)

        let style = await service.currentAlertStyle()
        #expect(style == .none)
    }
}
