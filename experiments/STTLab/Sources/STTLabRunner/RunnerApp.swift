import SwiftUI

@main
struct RunnerApp: App {
    init() {
        // CLI mode: if --cli is present, run headless and exit before any window opens.
        if CommandLine.arguments.contains("--cli") {
            RunnerCLI.main()
            // RunnerCLI.main() calls exit() and never returns.
        }
    }

    var body: some Scene {
        WindowGroup {
            RunnerView()
        }
        .defaultSize(width: 720, height: 560)
    }
}
