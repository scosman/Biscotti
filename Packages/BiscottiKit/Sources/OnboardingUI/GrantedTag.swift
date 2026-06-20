import DesignSystem
import SwiftUI

/// Non-interactive status tag: a small sage circle with a white
/// checkmark, followed by a kicker-styled label. Defaults to
/// "GRANTED" for permission rows; pass a custom label for other
/// contexts (e.g. "COMPLETE" for model download).
struct GrantedTag: View {
    private let label: String

    init(_ label: String = "GRANTED") {
        self.label = label
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.sage)
                .frame(width: 15, height: 15)
                .overlay(
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                )

            Text(label)
                .kicker()
                .foregroundStyle(.sage)
        }
    }
}
