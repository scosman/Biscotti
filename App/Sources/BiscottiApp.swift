import AppCore
import AppShellUI
import SwiftUI

/// The Biscotti app entry point.
///
/// Builds a fully-wired `AppCore` (DataStore, Permissions, Recording,
/// TranscriptionService) and presents the `AppShellView` in a single
/// `WindowGroup`. Window-only (regular activation, dock icon); the
/// `MenuBarExtra` is a later project.
///
/// - TODO: License/attribution screen for argmax-oss-swift and model
///   licenses must be added before ship (Project 9).
@main
struct BiscottiApp: App {
    @State private var core: AppCore?
    @State private var shellViewModel: AppShellViewModel?
    @State private var launchError: String?

    var body: some Scene {
        WindowGroup {
            Group {
                if let shellViewModel {
                    AppShellView(viewModel: shellViewModel)
                } else if let launchError {
                    errorView(message: launchError)
                } else {
                    ProgressView("Starting Biscotti\u{2026}")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 640, minHeight: 400)
            .task { buildCore() }
        }
    }

    private func buildCore() {
        do {
            let appSupport = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let storageRoot = appSupport.appendingPathComponent("Biscotti")
            try FileManager.default.createDirectory(
                at: storageRoot,
                withIntermediateDirectories: true
            )

            let appCore = try AppCore.live(
                storageRoot: storageRoot,
                transcriberServiceName: "net.scosman.biscotti.BiscottiTranscriber"
            )
            core = appCore
            shellViewModel = AppShellViewModel(core: appCore)
        } catch {
            launchError = error.localizedDescription
        }
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.red)
            Text("Failed to start Biscotti")
                .font(.headline)
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
