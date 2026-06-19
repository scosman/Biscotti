import SwiftUI

/// A generic "open System Settings" alert modifier.
///
/// Used by the system-audio permission flow (Settings, Onboarding,
/// and later the in-recording hint). Accepts title and body as
/// parameters so `DesignSystem` stays dependency-free -- the caller
/// passes the copy from `SystemAudioPermissionState` constants.
private struct FixPermissionsAlertModifier: ViewModifier {
    let title: String
    let body: String
    @Binding var isPresented: Bool
    let onOpenSettings: () -> Void

    func body(content: Content) -> some View {
        content.alert(
            title,
            isPresented: $isPresented
        ) {
            Button("Open System Settings") {
                onOpenSettings()
            }
            .keyboardShortcut(.defaultAction)
            Button("Done", role: .cancel) {}
        } message: {
            Text(body)
        }
    }
}

public extension View {
    /// Attaches a "fix permissions" alert that directs the user to
    /// System Settings.
    ///
    /// - Parameters:
    ///   - isPresented: Binding that controls alert presentation.
    ///   - title: Alert title text.
    ///   - body: Alert body text.
    ///   - onOpenSettings: Action to open System Settings (deeplink).
    func fixPermissionsAlert(
        isPresented: Binding<Bool>,
        title: String,
        body: String,
        onOpenSettings: @escaping () -> Void
    ) -> some View {
        modifier(
            FixPermissionsAlertModifier(
                title: title,
                body: body,
                isPresented: isPresented,
                onOpenSettings: onOpenSettings
            )
        )
    }
}
