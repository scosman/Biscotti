import SwiftUI

/// The label (icon + optional text) shown in the macOS menu bar.
public struct MenuBarLabelView: View {
    @Bindable var viewModel: MenuBarViewModel

    public init(viewModel: MenuBarViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        HStack(spacing: 4) {
            Image(
                systemName: viewModel.iconState == .recording
                    ? "record.circle.fill"
                    : "circle.dotted.circle"
            )
            if case let .nextMeeting(title, time) = viewModel
                .iconState
            {
                Text("\(title) \u{2013} \(time)")
                    .font(.caption)
                    .monospacedDigit()
            }
        }
    }
}
