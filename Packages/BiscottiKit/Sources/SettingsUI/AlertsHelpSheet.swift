import DesignSystem
import SwiftUI

/// Explanatory dialog guiding the user to switch Biscotti's macOS
/// notification style to "Alerts" in System Settings.
///
/// macOS controls notification dwell; there is no API to set it
/// programmatically. This sheet explains the three manual steps and
/// offers a deep-link button to open the Notifications settings pane.
struct AlertsHelpSheet: View {
    let viewModel: SettingsViewModel

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spacingMD) {
            Text("Keep Notifications On Screen")
                .font(.headline)

            Text(
                "macOS decides how long notifications stay on screen. To keep Biscotti\u{2019}s notifications visible until you dismiss them, set their style to \u{201C}Alerts\u{201D}."
            )

            VStack(alignment: .leading, spacing: Tokens.spacingSM) {
                stepRow(number: 1, text: "Open System Settings \u{2192} Notifications")
                stepRow(number: 2, text: "Select Biscotti")
                stepRow(number: 3, text: "Set the alert style to \u{201C}Alerts\u{201D}")
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Open Settings") {
                    viewModel.openNotificationSettings()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(.sage)
            }
        }
        .padding(Tokens.spacingMD * 1.5)
        .frame(width: 400)
    }

    private func stepRow(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: Tokens.spacingSM) {
            Text("\(number).")
                .monospacedDigit()
            Text(text)
        }
    }
}
