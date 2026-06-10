import SwiftUI

/// A prominent Record button styled with a red circle indicator.
///
/// Used in the sidebar as the primary recording action.
public struct RecordButton: View {
    private let isDisabled: Bool
    private let action: () -> Void

    public init(isDisabled: Bool = false, action: @escaping () -> Void) {
        self.isDisabled = isDisabled
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Label {
                Text("Record")
                    .fontWeight(.semibold)
            } icon: {
                Circle()
                    .fill(isDisabled ? Color.gray : Tokens.recordingRed)
                    .frame(width: 10, height: 10)
            }
        }
        .disabled(isDisabled)
        .buttonStyle(.plain)
        .padding(.vertical, Tokens.spacingSM)
    }
}

#Preview("Record Button - Enabled") {
    RecordButton {}
        .padding()
}

#Preview("Record Button - Disabled") {
    RecordButton(isDisabled: true) {}
        .padding()
}
