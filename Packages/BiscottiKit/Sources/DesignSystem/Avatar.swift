import SwiftUI

/// A circular avatar showing initials on a deterministic color background.
///
/// Color is derived from the person's email (or name as fallback) via
/// `avatarColorIndex`, ensuring the same person always gets the same
/// color across sessions.
public struct Avatar: View {
    private let person: AvatarPerson
    private let size: CGFloat
    private let stacked: Bool

    public init(person: AvatarPerson, size: CGFloat = Tokens.avatarSize, stacked: Bool = false) {
        self.person = person
        self.size = size
        self.stacked = stacked
    }

    private var colorKey: String {
        if let email = person.email, !email.isEmpty {
            return email
        }
        return person.displayName
    }

    private var baseColor: Color {
        let idx = avatarColorIndex(forKey: colorKey, paletteCount: Tokens.avatarPalette.count)
        return Tokens.avatarPalette[idx]
    }

    private var initials: String {
        avatarInitials(for: person.displayName)
    }

    public var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [baseColor, baseColor.opacity(0.7)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            // Inset hairline ring
            Circle()
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)

            if initials.isEmpty {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.4))
                    .foregroundStyle(.white)
            } else {
                Text(initials)
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .overlay {
            if stacked {
                Circle()
                    .strokeBorder(.white, lineWidth: 2)
            }
        }
    }
}

/// A row of overlapped avatars pinned to a fixed-width column.
///
/// Shows up to 3 overlapping avatars plus a "+N" neutral badge for
/// any remaining participants. The column width is fixed so all row
/// titles align at the same X coordinate.
public struct AvatarCluster: View {
    private let people: [AvatarPerson]
    private let totalCount: Int
    private let size: CGFloat
    private let columnWidth: CGFloat

    /// Maximum number of avatars rendered before the "+N" badge.
    private static let maxShown = 3

    public init(
        people: [AvatarPerson],
        totalCount: Int,
        size: CGFloat = Tokens.avatarSize,
        columnWidth: CGFloat = Tokens.avatarColumnWidth
    ) {
        self.people = people
        self.totalCount = totalCount
        self.size = size
        self.columnWidth = columnWidth
    }

    private var shownPeople: [AvatarPerson] {
        Array(people.prefix(Self.maxShown))
    }

    private var overflowCount: Int {
        max(0, totalCount - shownPeople.count)
    }

    private var overlap: CGFloat {
        size * 0.34
    }

    public var body: some View {
        HStack(spacing: -overlap) {
            ForEach(Array(shownPeople.enumerated()), id: \.element) { _, person in
                Avatar(person: person, size: size, stacked: shownPeople.count > 1)
            }

            if overflowCount > 0 {
                plusBadge
            }
        }
        .frame(width: columnWidth, alignment: .leading)
    }

    private var plusBadge: some View {
        ZStack {
            Circle()
                .fill(Color.secondary.opacity(0.15))

            Circle()
                .strokeBorder(.white, lineWidth: 2)

            Text("+\(overflowCount)")
                .font(.system(size: size * 0.35, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Previews

#Preview("Avatar Sizes") {
    HStack(spacing: 12) {
        Avatar(
            person: AvatarPerson(displayName: "Sam Altman", email: "sam@openai.com"),
            size: 28
        )
        Avatar(
            person: AvatarPerson(displayName: "Cher", email: nil),
            size: 26
        )
        Avatar(
            person: AvatarPerson(displayName: "", email: nil),
            size: 26
        )
    }
    .padding()
}

#Preview("AvatarCluster") {
    VStack(spacing: 16) {
        AvatarCluster(
            people: [
                AvatarPerson(displayName: "Sam Altman", email: "sam@openai.com"),
                AvatarPerson(displayName: "Dario Amodei", email: "dario@anthropic.com"),
                AvatarPerson(displayName: "Satya Nadella", email: "satya@microsoft.com")
            ],
            totalCount: 7,
            size: 28
        )

        AvatarCluster(
            people: [
                AvatarPerson(displayName: "Alice", email: "alice@example.com")
            ],
            totalCount: 1,
            size: 26
        )
    }
    .padding()
}
