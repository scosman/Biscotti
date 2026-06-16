import Notifications
import Testing
import UserNotifications

@Suite("Category / action registration")
struct CategoryRegistrationTests {
    @Test("Registers all four categories on init")
    @MainActor
    func registersCategoriesOnInit() {
        let fake = FakeNotificationCenter()
        _ = NotificationService(provider: fake)

        #expect(fake.setCategoriesCalls.count == 1)
        let categories = fake.setCategoriesCalls[0]
        #expect(categories.count == 4)

        let ids = Set(categories.map(\.identifier))
        #expect(ids.contains("biscotti.meeting-starting"))
        #expect(ids.contains("biscotti.meeting-starting-with-join"))
        #expect(ids.contains("biscotti.ad-hoc-detected"))
        #expect(ids.contains("biscotti.stop-countdown"))
    }

    @Test("Meeting-starting category has Open & Record action with foreground")
    @MainActor
    func meetingStartingActions() throws {
        let fake = FakeNotificationCenter()
        _ = NotificationService(provider: fake)

        let categories = fake.setCategoriesCalls[0]
        let category = try #require(categories.first { $0.identifier == "biscotti.meeting-starting" })
        #expect(category.actions.count == 1)
        #expect(category.actions[0].identifier == "biscotti.action.open-and-record")
        #expect(category.actions[0].options.contains(.foreground))
    }

    @Test("Meeting-starting-with-join has Open & Record and Join actions")
    @MainActor
    func meetingStartingWithJoinActions() throws {
        let fake = FakeNotificationCenter()
        _ = NotificationService(provider: fake)

        let categories = fake.setCategoriesCalls[0]
        let category = try #require(categories.first {
            $0.identifier == "biscotti.meeting-starting-with-join"
        })
        #expect(category.actions.count == 2)

        let actionIDs = category.actions.map(\.identifier)
        #expect(actionIDs.contains("biscotti.action.open-and-record"))
        #expect(actionIDs.contains("biscotti.action.join"))

        // Both should have foreground option
        for action in category.actions {
            #expect(action.options.contains(.foreground))
        }
    }

    @Test("Ad-hoc category has Record action without foreground")
    @MainActor
    func adHocActions() throws {
        let fake = FakeNotificationCenter()
        _ = NotificationService(provider: fake)

        let categories = fake.setCategoriesCalls[0]
        let category = try #require(categories.first {
            $0.identifier == "biscotti.ad-hoc-detected"
        })
        #expect(category.actions.count == 1)
        #expect(category.actions[0].identifier == "biscotti.action.record")
        #expect(!category.actions[0].options.contains(.foreground))
    }

    @Test("Stop-countdown category has Keep Recording action with foreground")
    @MainActor
    func stopCountdownActions() throws {
        let fake = FakeNotificationCenter()
        _ = NotificationService(provider: fake)

        let categories = fake.setCategoriesCalls[0]
        let category = try #require(categories.first {
            $0.identifier == "biscotti.stop-countdown"
        })
        #expect(category.actions.count == 1)
        #expect(category.actions[0].identifier == "biscotti.action.keep-recording")
        #expect(category.actions[0].options.contains(.foreground))
    }
}
