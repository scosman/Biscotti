import SwiftUI

/// A prominent "Start Recording" button for the Home screen.
///
/// Uses `.borderedProminent` with a red tint, `.controlSize(.large)`,
/// and a record-circle icon. Separate from `RecordButton` (which is
/// the compact sidebar/event-preview variant).
public struct StartRecordingButton: View {
    private let isDisabled: Bool
    private let action: () -> Void

    public init(isDisabled: Bool, action: @escaping () -> Void) {
        self.isDisabled = isDisabled
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Label {
                Text("Start Recording")
                    .fontWeight(.semibold)
            } icon: {
                Image(systemName: "record.circle")
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(Tokens.recordingRed)
        .disabled(isDisabled)
    }
}

#Preview("Start Recording - Enabled") {
    StartRecordingButton(isDisabled: false) {}
        .padding()
}

#Preview("Start Recording - Disabled") {
    StartRecordingButton(isDisabled: true) {}
        .padding()
}
