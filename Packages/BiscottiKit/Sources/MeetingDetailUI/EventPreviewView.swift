import AppKit
import Calendar
import DesignSystem
import SwiftUI

/// Read-only preview of an upcoming calendar event with time-gated
/// action prominence: buttons are visually prominent only within
/// 5 min before start through 5 min after end.
///
/// Shown when the user selects an upcoming event in the sidebar.
/// Redesigned to match the new-style MeetingDetailView: serif title,
/// meta line with SourcePill, dedicated event details card with
/// custom attendee section.
public struct EventPreviewView: View {
    private let viewModel: EventPreviewViewModel

    /// Transient "Copied" feedback for the Copy Link button.
    @State private var didCopyLink = false

    /// Timer that reverts `didCopyLink` after the feedback window.
    @State private var copyResetTask: Task<Void, Never>?

    public init(viewModel: EventPreviewViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        if let event = viewModel.event {
            eventContent(event)
                .onDisappear {
                    copyResetTask?.cancel()
                    copyResetTask = nil
                }
        } else {
            VStack(spacing: Tokens.spacingSM) {
                Text("Event not found")
                    .font(Tokens.metadataFont)
                    .foregroundStyle(Tokens.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Main content

    private func eventContent(_ event: CalendarEvent) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header(event)

                actionBar
                    .padding(.top, Tokens.spacingMD)

                eventDetailsCard(event)
                    .padding(.top, Tokens.spacingMD)

                Spacer()
            }
            .padding(.horizontal, Tokens.homeHorizontalPadding)
            .padding(.top, Tokens.homeVerticalPadding)
            .padding(.bottom, Tokens.homeVerticalPadding)
            .frame(maxWidth: Tokens.readableContentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Tokens.contentBackground)
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
    }
}

// MARK: - Header

private extension EventPreviewView {
    func header(_ event: CalendarEvent) -> some View {
        VStack(alignment: .leading, spacing: Tokens.spacingXS) {
            Text(event.title)
                .font(.biscottiSerif(27))
                .tracking(-0.27)
                .foregroundStyle(.ink)

            metaLine(event)
        }
    }

    func metaLine(_ event: CalendarEvent) -> some View {
        HStack(spacing: Tokens.spacingSM) {
            Text(viewModel.relativeTimeText)
                .font(.monoMetaMedium)
                .foregroundStyle(.sage)

            if let duration = viewModel.formattedDuration {
                Text("\u{00B7}")
                    .foregroundStyle(.inkTertiary)
                Text(duration)
                    .font(.monoMeta)
                    .foregroundStyle(.inkSecondary)
            }

            if let platform = event.conferencePlatform {
                Text("\u{00B7}")
                    .foregroundStyle(.inkTertiary)
                SourcePill(platform: platform)
            }
        }
    }
}

// MARK: - Action buttons

private extension EventPreviewView {
    var actionBar: some View {
        HStack(spacing: Tokens.spacingSM) {
            primaryButton

            openInCalendarButton

            if viewModel.showCopyLink {
                copyLinkButton
            }
        }
    }

    @ViewBuilder
    var primaryButton: some View {
        switch viewModel.primaryAction {
        case .joinAndRecord:
            if viewModel.isProminent {
                Button {
                    Task { await viewModel.joinAndRecord() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "record.circle")
                        Text("Join & Record")
                    }
                }
                .buttonStyle(JoinRecordButtonStyle())
                .controlSize(.large)
                .disabled(viewModel.recordDisabled)
            } else {
                Button {
                    Task { await viewModel.joinAndRecord() }
                } label: {
                    Label("Join & Record", systemImage: "record.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(viewModel.recordDisabled)
            }

        case .record:
            if viewModel.isProminent {
                Button {
                    Task { await viewModel.startRecording() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "record.circle")
                        Text("Record")
                    }
                }
                .buttonStyle(JoinRecordButtonStyle())
                .controlSize(.large)
                .disabled(viewModel.recordDisabled)
            } else {
                Button {
                    Task { await viewModel.startRecording() }
                } label: {
                    Label("Record", systemImage: "record.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(viewModel.recordDisabled)
            }
        }
    }

    var openInCalendarButton: some View {
        Button {
            viewModel.openInCalendar()
        } label: {
            Label("Open in Calendar", systemImage: "calendar")
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    var copyLinkButton: some View {
        Button {
            viewModel.copyLink()
            didCopyLink = true
            copyResetTask?.cancel()
            copyResetTask = Task {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                didCopyLink = false
            }
        } label: {
            Label(
                didCopyLink ? "Copied" : "Copy Link",
                systemImage: didCopyLink ? "checkmark" : "doc.on.doc"
            )
            .transaction { $0.animation = nil }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }
}

// MARK: - Event details card

private extension EventPreviewView {
    func eventDetailsCard(_ event: CalendarEvent) -> some View {
        detailsGrid(event)
            .padding(Tokens.spacingMD)
            .background(
                RoundedRectangle(cornerRadius: Tokens.cardRadius)
                    .fill(Tokens.cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.cardRadius)
                    .strokeBorder(Color.cardStroke, lineWidth: 0.5)
            )
    }

    func detailsGrid(_ event: CalendarEvent) -> some View {
        Grid(
            alignment: .leadingFirstTextBaseline,
            horizontalSpacing: 16,
            verticalSpacing: 14
        ) {
            // WHEN
            if let when = viewModel.formattedDateRange {
                GridRow {
                    Text("WHEN")
                        .kicker()
                        .foregroundStyle(.inkTertiary)
                        .gridColumnAlignment(.leading)
                    Text(when)
                        .font(.monoMeta)
                        .foregroundStyle(.ink)
                        .textSelection(.enabled)
                }
            }

            // WHERE
            if event.conferencePlatform != nil || event.location.flatMap({ $0.isEmpty ? nil : $0 }) != nil {
                GridRow {
                    Text("WHERE")
                        .kicker()
                        .foregroundStyle(.inkTertiary)
                    whereContent(event)
                }
            }

            // ATTENDEES
            if viewModel.avatarData.total > 0 {
                GridRow {
                    Text("ATTENDEES (\(viewModel.avatarData.total))")
                        .kicker()
                        .foregroundStyle(.inkTertiary)
                    attendeesContent
                }
            }

            // DESCRIPTION
            if let notes = event.notes, !notes.isEmpty {
                GridRow {
                    Text("DESCRIPTION")
                        .kicker()
                        .foregroundStyle(.inkTertiary)
                    Text(notes)
                        .font(.system(size: 13))
                        .foregroundStyle(.inkSecondary)
                        .frame(maxWidth: 460, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
        }
    }

    func whereContent(_ event: CalendarEvent) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let platform = event.conferencePlatform {
                HStack(spacing: 4) {
                    Image(systemName: "video.fill")
                        .foregroundStyle(.sage)
                        .font(.system(size: 10))
                    Text(platform)
                        .font(.system(size: 13))
                        .foregroundStyle(.ink)
                    if let url = event.conferenceURL {
                        Link(url.absoluteString, destination: url)
                            .font(.monoMeta)
                            .foregroundStyle(.sage)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            if let location = event.location, !location.isEmpty {
                Text(location)
                    .font(.system(size: 13))
                    .foregroundStyle(.inkSecondary)
                    .textSelection(.enabled)
            }
        }
    }

    var attendeesContent: some View {
        let data = viewModel.avatarData
        let emails = viewModel.attendeeEmailLines
        let maxEmails = 16
        let shownEmails = Array(emails.prefix(maxEmails))
        let overflow = emails.count - shownEmails.count

        return VStack(alignment: .leading, spacing: Tokens.spacingSM) {
            // Avatar row (up to 8 before overflow).
            // Wider columnWidth than default (80pt) to avoid clipping
            // when showing 8 overlapping avatars + optional "+N" badge.
            AvatarCluster(
                people: data.people,
                totalCount: data.total,
                size: Tokens.avatarSize,
                columnWidth: 240,
                maxCount: 8
            )

            // Email list (wrapping, up to 16)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(
                    Array(shownEmails.enumerated()),
                    id: \.offset
                ) { _, email in
                    Text(email)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.inkSecondary)
                        .textSelection(.enabled)
                }
                if overflow > 0 {
                    Text(
                        "and \(overflow) other\(overflow == 1 ? "" : "s")"
                    )
                    .font(.system(size: 12.5))
                    .foregroundStyle(.inkTertiary)
                }
            }

            // Domain summary (only when >1 distinct domain)
            if let domains = viewModel.domainSummary {
                Text(domains)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.inkTertiary)
            }
        }
    }
}
