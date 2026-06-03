import SwiftUI

@main
struct EventKitLabApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 750, minHeight: 550)
        }
    }
}

struct ContentView: View {
    enum Tab: String, CaseIterable {
        case permission = "Permission"
        case calendars = "Calendars"
        case events = "Events"
        case report = "Data Report"
    }

    @State private var selectedTab: Tab = .permission
    @State private var manager = CalendarAccessManager()

    var body: some View {
        TabView(selection: $selectedTab) {
            PermissionView(manager: manager)
                .tabItem { Label("Permission", systemImage: "lock.shield") }
                .tag(Tab.permission)
            CalendarsView(manager: manager)
                .tabItem { Label("Calendars", systemImage: "calendar") }
                .tag(Tab.calendars)
            EventsView(manager: manager)
                .tabItem { Label("Events", systemImage: "list.bullet.rectangle") }
                .tag(Tab.events)
            DataReportView(manager: manager)
                .tabItem { Label("Data Report", systemImage: "doc.text") }
                .tag(Tab.report)
        }
        .padding()
    }
}
