import SwiftUI

@main
struct AudioLabApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 700, minHeight: 500)
        }
    }
}

struct ContentView: View {
    enum Tab: String, CaseIterable {
        case streams = "Streams"
        case record = "Record"
    }

    @State private var selectedTab: Tab = .streams

    var body: some View {
        TabView(selection: $selectedTab) {
            StreamsView()
                .tabItem { Label("Streams", systemImage: "waveform") }
                .tag(Tab.streams)
            RecordView()
                .tabItem { Label("Record", systemImage: "record.circle") }
                .tag(Tab.record)
        }
        .padding()
    }
}
