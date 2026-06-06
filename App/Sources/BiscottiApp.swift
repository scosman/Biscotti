import BiscottiKit
import SwiftUI

@main
struct BiscottiApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 8) {
                Text("Biscotti").font(.largeTitle)
                Text(BiscottiKit.marker).foregroundStyle(.secondary)
            }
            .frame(minWidth: 360, minHeight: 240)
            .padding()
        }
    }
}
