import AppCore
import Calendar
import DesignSystem
import SwiftUI

/// The Home screen: welcome text, a prominent Start Recording button,
/// and a preview of upcoming meeting-like events (or an empty state).
public struct HomeView: View {
    @Bindable private var viewModel: HomeViewModel

    public init(viewModel: HomeViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Welcome text
            Text("Welcome to Biscotti")
                .font(.title2)
                .padding(.bottom, Tokens.spacingXS)

            Text("Private, on-device meeting transcripts")
                .font(Tokens.metadataFont)
                .foregroundStyle(Tokens.secondaryText)

            Spacer()
                .frame(minHeight: Tokens.spacingLG)

            // Start Recording (centered, prominent)
            RecordButton(isDisabled: viewModel.startDisabled) {
                Task { await viewModel.startRecording() }
            }

            Spacer()
                .frame(minHeight: Tokens.spacingLG)

            // Upcoming section
            upcomingSection

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Tokens.spacingXL)
    }

    @ViewBuilder
    private var upcomingSection: some View {
        if viewModel.showConnectCalendar {
            VStack(spacing: Tokens.spacingSM) {
                Text("Connect your calendar to see upcoming meetings")
                    .font(Tokens.metadataFont)
                    .foregroundStyle(Tokens.secondaryText)
                    .multilineTextAlignment(.center)

                Button("Allow Calendar Access") {
                    Task { await viewModel.requestCalendarAccess() }
                }
                .buttonStyle(.bordered)
            }
        } else if viewModel.showNoUpcoming {
            Text("No meetings coming up.")
                .font(Tokens.metadataFont)
                .foregroundStyle(Tokens.secondaryText)
        } else if !viewModel.upcomingPreview.isEmpty {
            VStack(alignment: .leading, spacing: Tokens.spacingXS) {
                Text("Upcoming")
                    .font(Tokens.sectionHeaderFont)
                    .foregroundStyle(Tokens.secondaryText)

                ForEach(viewModel.upcomingPreview) { event in
                    Button {
                        viewModel.selectEvent(event.id)
                    } label: {
                        UpcomingEventRow(
                            title: event.title,
                            timeText: viewModel.tickTimeText(for: event),
                            platformBadge: event.conferencePlatform
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 400)
        }
    }
}

#Preview("Home - No Calendar") {
    let core = try! PreviewAppCore.make() // swiftlint:disable:this force_try
    let viewModel = HomeViewModel(core: core)
    HomeView(viewModel: viewModel)
        .frame(width: 500, height: 400)
}
