import DesignSystem
import SwiftUI

/// Renders the ordered processing-pipeline stages on the Summary tab
/// while a meeting is being transcribed and/or enhanced.
///
/// Each stage shows a leading glyph (checkmark for done, small spinner
/// for active, dim circle for pending) and a label. Reuses the existing
/// small-spinner idiom from the streaming summary header.
struct EnhancementPipelineView: View {
    let stages: [PipelineStage]

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spacingSM) {
            ForEach(stages) { stage in
                HStack(spacing: Tokens.spacingSM) {
                    stageGlyph(stage.state)
                        .frame(width: 16, height: 16)

                    Text(stage.label)
                        .font(.monoMeta)
                        .foregroundStyle(
                            stage.state == .pending
                                ? .inkTertiary : .inkSecondary
                        )
                }
            }
        }
    }

    @ViewBuilder
    private func stageGlyph(_ state: StageState) -> some View {
        switch state {
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.inkSecondary)

        case .active:
            ProgressView()
                .controlSize(.small)

        case .pending:
            Image(systemName: "circle")
                .font(.system(size: 9))
                .foregroundStyle(.inkTertiary)
        }
    }
}
