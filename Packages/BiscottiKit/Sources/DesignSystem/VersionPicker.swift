import SwiftUI

/// Describes a single transcript version for the picker.
public struct VersionPickerItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let dateText: String
    public let methodLabel: String
    public let isPreferred: Bool

    public init(
        id: UUID,
        dateText: String,
        methodLabel: String,
        isPreferred: Bool
    ) {
        self.id = id
        self.dateText = dateText
        self.methodLabel = methodLabel
        self.isPreferred = isPreferred
    }
}

/// A macOS Menu-button dropdown listing transcript versions.
///
/// Shows the selected version's date; the menu lists all versions with
/// their method and a "Preferred" badge on the preferred version.
public struct VersionPicker: View {
    public let versions: [VersionPickerItem]
    public let selectedID: UUID
    public let onSelect: (UUID) -> Void

    public init(
        versions: [VersionPickerItem],
        selectedID: UUID,
        onSelect: @escaping (UUID) -> Void
    ) {
        self.versions = versions
        self.selectedID = selectedID
        self.onSelect = onSelect
    }

    public var body: some View {
        Menu {
            ForEach(versions) { version in
                Button {
                    onSelect(version.id)
                } label: {
                    HStack {
                        Text(version.dateText)
                        Text("(\(version.methodLabel))")
                            .foregroundStyle(.secondary)
                        if version.isPreferred {
                            Text("- Preferred")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } label: {
            Label("Version", systemImage: "doc.on.doc")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

#Preview("Version Picker") {
    VersionPicker(
        versions: [
            VersionPickerItem(
                id: UUID(),
                dateText: "Jun 10, 2026",
                methodLabel: "whisperkit",
                isPreferred: true
            ),
            VersionPickerItem(
                id: UUID(),
                dateText: "Jun 9, 2026",
                methodLabel: "whisperkit",
                isPreferred: false
            )
        ],
        selectedID: UUID(),
        onSelect: { _ in }
    )
    .padding()
}
