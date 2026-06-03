import SwiftUI

struct DataReportView: View {
    let manager: CalendarAccessManager

    @State private var reportText = ""
    @State private var copied = false

    var body: some View {
        VStack(spacing: 12) {
            Text("Data Availability Report")
                .font(.title)

            if !manager.hasCalendarAccess {
                Text("Calendar access not granted. Go to the Permission tab first.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {

            HStack {
                Button("Generate Report") {
                    reportText = manager.generateDataReport()
                }
                .buttonStyle(.borderedProminent)
                .disabled(manager.snapshots.isEmpty)

                Button("Copy to Clipboard") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(reportText, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copied = false
                    }
                }
                .disabled(reportText.isEmpty)

                if copied {
                    Text("Copied!")
                        .foregroundStyle(.green)
                        .font(.caption)
                }

                Spacer()

                Text("\(manager.snapshots.count) events available")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .padding(.horizontal)

            if manager.snapshots.isEmpty {
                Text("Load events first from the Events tab, then come back to generate the report.")
                    .foregroundStyle(.secondary)
                    .padding()
                Spacer()
            } else if reportText.isEmpty {
                Text("Click \"Generate Report\" to dump all event fields.")
                    .foregroundStyle(.secondary)
                    .padding()
                Spacer()
            } else {
                ScrollView {
                    Text(reportText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            } // else hasCalendarAccess
        }
        .padding()
    }
}
