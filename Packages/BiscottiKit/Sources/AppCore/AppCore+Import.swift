import AudioImport
import Foundation

// MARK: - Import auto-navigation

/// Pure predicate for single-file import auto-navigation.
public enum ImportAutoNavigation {
    public static func shouldNavigate(
        batchSize: Int,
        controllerHasPendingWork: Bool,
        route: Route
    ) -> Bool {
        batchSize == 1 && !controllerHasPendingWork && route == .importing
    }
}

// MARK: - Import wiring

public extension AppCore {
    /// Adds files to the import session and shows the Import screen.
    /// No-op during onboarding (route == .onboarding) or if entries is empty.
    func importFiles(_ entries: [ImportEntry]) {
        guard route != .onboarding, !entries.isEmpty else { return }
        audioImport.add(entries)
        route = .importing
    }

    /// Sidebar "Imported" row: routes to the Import screen.
    func showImport() {
        route = .importing
    }

    /// File > Import Audio File... request. The App sets it; AppShellView
    /// consumes it by presenting `.fileImporter`.
    func requestImportPanel() {
        guard route != .onboarding else { return }
        importPanelRequested = true
    }

    /// Clears the import panel request flag after the panel is presented.
    func consumeImportPanelRequest() {
        importPanelRequested = false
    }
}
