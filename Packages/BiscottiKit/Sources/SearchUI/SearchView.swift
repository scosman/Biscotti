import AppCore
import DataStore
import DesignSystem
import SwiftUI

/// The search results takeover view. Shows ranked results matching
/// the user's query, a back button, and empty/loading states.
public struct SearchView: View {
    @Bindable private var viewModel: SearchViewModel

    public init(viewModel: SearchViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Back button
            HStack {
                Button {
                    viewModel.dismiss()
                } label: {
                    HStack(spacing: Tokens.spacingXS) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                    .font(.body)
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.horizontal, Tokens.spacingMD)
            .padding(.vertical, Tokens.spacingSM)

            Divider()

            // Content
            if viewModel.isSearching {
                VStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if viewModel.showNoResults {
                VStack {
                    Spacer()
                    Text(viewModel.noResultsMessage)
                        .font(Tokens.metadataFont)
                        .foregroundStyle(Tokens.secondaryText)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .padding(Tokens.spacingMD)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(viewModel.results) { hit in
                            Button {
                                viewModel.selectResult(hit.id)
                            } label: {
                                searchResultRow(hit)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func searchResultRow(_ hit: SearchHit) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(hit.title)
                    .font(.body)
                    .lineLimit(1)
                Spacer()
                Text(Self.formatDate(hit.date))
                    .font(Tokens.metadataFont)
                    .foregroundStyle(Tokens.secondaryText)
            }
            Text("matches: \(SearchViewModel.matchedFieldsText(hit.matchedFields))")
                .font(.caption)
                .foregroundStyle(Tokens.secondaryText)
        }
        .padding(.horizontal, Tokens.spacingMD)
        .padding(.vertical, Tokens.spacingSM)
        .contentShape(Rectangle())
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private static func formatDate(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }
}

#Preview("Search - Empty") {
    let core = try! PreviewAppCore.make() // swiftlint:disable:this force_try
    let viewModel = SearchViewModel(core: core)
    SearchView(viewModel: viewModel)
        .frame(width: 500, height: 400)
}
