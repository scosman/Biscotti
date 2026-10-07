#if DEBUG

    import AppKit
    import DataStore
    import DesignSystem
    import Intelligence
    import SwiftUI
    import VoiceprintMatching

    struct VoiceprintDebugView: View {
        let report: VoiceprintDebugReport
        let onDismiss: () -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: Tokens.spacingMD) {
                header
                summaryLine
                levelLine
                candidatesTable
                neighborsTable
                llmBlockSection
            }
            .padding(Tokens.spacingMD)
            .frame(width: 900, height: 700)
        }

        // MARK: - Sections

        private var header: some View {
            HStack {
                Text("Speaker \(report.speakerID)")
                    .font(.headline)

                Spacer()

                Button("Done") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }

        @ViewBuilder
        private var summaryLine: some View {
            if let error = report.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.callout)
            } else if !report.hasVoiceprint {
                Text("No voiceprint for this speaker")
                    .foregroundStyle(.inkSecondary)
                    .font(.callout)
            } else {
                HStack(spacing: Tokens.spacingSM) {
                    if let space = report.space {
                        Text("Space: \(space)")
                    }
                    Text("\(report.corpusVoiceprints) voiceprints")
                    Text("\(report.corpusMeetings) meetings")
                }
                .font(.callout)
                .foregroundStyle(.inkSecondary)
            }
        }

        @ViewBuilder
        private var levelLine: some View {
            if let level = report.level {
                Text("Level: \(level.rawValue)")
                    .font(.system(.body, weight: .semibold))
            }
        }

        @ViewBuilder
        private var candidatesTable: some View {
            if !report.candidates.isEmpty {
                Text("Candidates")
                    .font(.subheadline.bold())
                Table(report.candidates) {
                    TableColumn("Name", value: \.name)
                    TableColumn("Email") { candidate in Text(candidate.email ?? "") }
                    TableColumn("Score") { candidate in
                        Text(String(format: "%.3f", candidate.score))
                    }
                    TableColumn("Distance") { candidate in
                        Text(String(format: "%.4f", candidate.distance))
                    }
                    TableColumn("Meetings") { candidate in
                        Text("\(candidate.countedMeetings)")
                    }
                    TableColumn("Confirmed") { candidate in
                        Text("\(candidate.confirmedMeetings)")
                    }
                    TableColumn("Invited") { candidate in
                        Text(candidate.invited ? "Yes" : "")
                    }
                }
                .frame(minHeight: 100, maxHeight: 180)
            }
        }

        @ViewBuilder
        private var neighborsTable: some View {
            if !report.neighbors.isEmpty {
                Text("Nearest Voiceprints")
                    .font(.subheadline.bold())
                Table(report.neighbors) {
                    TableColumn("Meeting", value: \.meetingTitle)
                    TableColumn("Date") { neighbor in
                        Text(neighbor.meetingDate, style: .date)
                    }
                    TableColumn("Speaker") { neighbor in Text("\(neighbor.speakerID)") }
                    TableColumn("Person") { neighbor in
                        Text(neighbor.personName ?? "unnamed")
                    }
                    TableColumn("Tag") { neighbor in
                        if let confirmed = neighbor.confirmed {
                            Text(confirmed ? "confirmed" : "inferred")
                        }
                    }
                    TableColumn("Distance") { neighbor in
                        Text(String(format: "%.4f", neighbor.distance))
                            .foregroundStyle(
                                neighbor.insideRadius ? Color.ink : Color.inkSecondary
                            )
                    }
                    TableColumn("Speaking") { neighbor in
                        Text(String(format: "%.0fs", neighbor.speakingDuration))
                    }
                }
                .frame(minHeight: 100, maxHeight: 200)
            }
        }

        @ViewBuilder
        private var llmBlockSection: some View {
            if !report.llmBlock.isEmpty {
                HStack {
                    Text("LLM Block")
                        .font(.subheadline.bold())
                    Spacer()
                    Button("Copy") {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(report.llmBlock, forType: .string)
                    }
                    .controlSize(.small)
                }
                ScrollView {
                    Text(report.llmBlock)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 150)
            }
        }
    }

#endif
