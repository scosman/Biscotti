import SwiftUI

@main
struct ManualTestAppApp: App {
    var body: some Scene {
        WindowGroup {
            ScriptTabView()
                .frame(minWidth: 700, minHeight: 500)
        }
    }
}
