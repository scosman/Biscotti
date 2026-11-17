import DesignSystem
import SwiftUI

/// The Import screen: header (serif title + status line) and a card
/// listing every item in the import session.
public struct ImportView: View {
    let viewModel: ImportViewModel

    public init(viewModel: ImportViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                headerSection
                    .padding(.bottom, 26)

                listCard
            }
            .frame(maxWidth: Tokens.contentColumnMaxWidth)
            .padding(.top, 72)
            .padding(.bottom, 48)
            .padding(.horizontal, Tokens.homeHorizontalPadding)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 12) {
            Text(viewModel.header.title)
                .font(.biscottiSerif(30))
                .tracking(-0.3)
                .foregroundStyle(Color.ink)
                .multilineTextAlignment(.center)

            if viewModel.header.statusIsMono {
                Text(viewModel.header.status)
                    .font(.biscottiMono(13))
                    .foregroundStyle(Color.inkSecondary)
                    .multilineTextAlignment(.center)
            } else {
                Text(viewModel.header.status)
                    .font(.system(size: 15))
                    .foregroundStyle(Color.inkSecondary)
                    .frame(maxWidth: 440)
                    .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: - List card

    private var listCard: some View {
        VStack(spacing: 0) {
            LazyVStack(spacing: 0) {
                let rows = viewModel.rows
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 {
                        Color.hairline.frame(height: 0.5)
                    }
                    ImportRowView(row: row, viewModel: viewModel)
                }
            }
        }
        .background(Color.cardFill)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.cardRadius)
                .strokeBorder(Color.cardStroke, lineWidth: 0.5)
        )
    }
}

/// A single row in the import list card.
struct ImportRowView: View {
    let row: ImportRowModel
    let viewModel: ImportViewModel

    var body: some View {
        HStack(spacing: 14) {
            iconTile
            nameColumn
            trailingContent
                .fixedSize()
        }
        .frame(height: 60)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
    }

    // MARK: - Icon tile

    private var iconTile: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(iconFill)
            .frame(width: 32, height: 32)
            .overlay {
                iconGlyph
            }
    }

    private var iconFill: Color {
        switch row.icon {
        case .sage: Color.softSageFill
        case .neutral: Color.neutralChip
        case .failed: Color.signalRed.opacity(0.11)
        }
    }

    @ViewBuilder
    private var iconGlyph: some View {
        switch row.icon {
        case .sage:
            Image(systemName: "waveform")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.sage)
        case .neutral:
            Image(systemName: "waveform")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.inkTertiary)
        case .failed:
            Image(systemName: "exclamationmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.signalRed)
        }
    }

    // MARK: - Name column

    private var nameColumn: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(row.name)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.ink)
                .lineLimit(1)
                .truncationMode(.middle)

            if row.secondLineIsError {
                Text(row.secondLine)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.signalRedText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Text(row.secondLine)
                    .font(.biscottiMono(12))
                    .foregroundStyle(Color.inkSecondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Trailing

    @ViewBuilder
    private var trailingContent: some View {
        switch row.trailing {
        case .waiting:
            Text("Waiting")
                .font(.biscottiMono(13))
                .foregroundStyle(Color.inkTertiary)

        case .receiving:
            Text("Receiving\u{2026}")
                .font(.biscottiMono(13))
                .foregroundStyle(Color.inkTertiary)

        case .converting:
            HStack(spacing: 9) {
                ProgressView()
                    .controlSize(.small)
                Text("Converting\u{2026}")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.inkSecondary)
            }

        case let .goToMeeting(meetingID):
            Button("Go to Meeting") {
                viewModel.goToMeeting(meetingID)
            }
            .buttonStyle(BezelButtonStyle())

        case .deleted:
            Text("Deleted")
                .font(.system(size: 13))
                .foregroundStyle(Color.inkTertiary)

        case .showInFinder:
            Button("Show in Finder") {
                viewModel.showInFinder(row.id)
            }
            .buttonStyle(BezelButtonStyle())

        case .none:
            EmptyView()
        }
    }

    // MARK: - Accessibility

    private var accessibilityLabel: String {
        "\(row.name), \(row.secondLine)"
    }

    private var accessibilityValue: String {
        switch row.trailing {
        case .waiting: "Waiting"
        case .receiving: "Receiving"
        case .converting: "Converting"
        case .goToMeeting: "Done"
        case .deleted: "Deleted"
        case .showInFinder: "Failed"
        case .none: ""
        }
    }
}
