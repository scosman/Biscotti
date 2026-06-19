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
/// Caps visible circles at `maxCount` (default 4). The recording badge
/// and the "+N" overflow chip each consume a slot in that budget.
/// Overflow is triggered by `max(people.count, totalCount)` so the cap
/// holds even when the calendar reports more attendees than it provides
/// names for.
///
/// The column width is fixed so all row titles align at the same X.
public struct AvatarCluster: View {
    private let people: [AvatarPerson]
    private let totalCount: Int
    private let size: CGFloat
    private let columnWidth: CGFloat
    private let showLeadingRecordingAvatar: Bool

    /// Maximum total visible circles (recording badge + name avatars +
    /// overflow chip). Defaults to 4. Callers can raise this (e.g. 8
    /// for expanded views).
    private let maxCount: Int

    public init(
        people: [AvatarPerson],
        totalCount: Int,
        size: CGFloat = Tokens.avatarSize,
        columnWidth: CGFloat = Tokens.avatarColumnWidth,
        showLeadingRecordingAvatar: Bool = false,
        maxCount: Int = 4
    ) {
        self.people = people
        self.totalCount = totalCount
        self.size = size
        self.columnWidth = columnWidth
        self.showLeadingRecordingAvatar = showLeadingRecordingAvatar
        self.maxCount = maxCount
    }

    private var shownPeople: [AvatarPerson] {
        let limit = avatarNameLimit(
            peopleCount: people.count,
            totalCount: totalCount,
            maxCount: maxCount,
            hasRecordingBadge: showLeadingRecordingAvatar
        )
        return Array(people.prefix(limit))
    }

    private var overflowCount: Int {
        max(0, totalCount - shownPeople.count)
    }

    /// Whether person avatars should show the white stacked border ring.
    ///
    /// For standard (non-recording) clusters this preserves the original
    /// behavior: border only when multiple people are shown. For clusters
    /// with a leading recording avatar the border is applied whenever
    /// any circle overlaps another (people, overflow badge, or mic).
    private var isStacked: Bool {
        if showLeadingRecordingAvatar {
            let visibleCircles = shownPeople.count
                + (overflowCount > 0 ? 1 : 0)
                + 1 // recording badge
            return visibleCircles > 1
        }
        return shownPeople.count > 1
    }

    private var overlap: CGFloat {
        size * 0.35
    }

    public var body: some View {
        HStack(spacing: -overlap) {
            if showLeadingRecordingAvatar {
                RecordingAvatar(size: size, stacked: isStacked)
            }

            ForEach(Array(shownPeople.enumerated()), id: \.element) { _, person in
                Avatar(person: person, size: size, stacked: isStacked)
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
                .fill(Color.inkSecondary.opacity(0.28))

            Circle()
                .strokeBorder(.white, lineWidth: 2)

            Text("+\(overflowCount)")
                .font(.monoBadge)
                .foregroundStyle(.inkSecondary)
        }
        .frame(width: size, height: size)
    }
}

/// A circular avatar showing a microphone SF Symbol on a grey background.
///
/// Used as the leading element in `AvatarCluster` for past meeting rows
/// to guarantee the avatar section is never visually blank.
public struct RecordingAvatar: View {
    private let size: CGFloat
    private let stacked: Bool

    public init(size: CGFloat = Tokens.avatarSize, stacked: Bool = false) {
        self.size = size
        self.stacked = stacked
    }

    public var body: some View {
        ZStack {
            Circle()
                .fill(Color.ink.opacity(0.22))

            // Inset hairline ring (matches person avatar treatment)
            Circle()
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)

            Image(systemName: "microphone")
                .font(.system(size: size * 0.4, weight: .medium))
                .foregroundStyle(.white)
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
    .background(Tokens.contentBackground)
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
    .background(Tokens.contentBackground)
}

#Preview("AvatarCluster Recording") {
    VStack(alignment: .leading, spacing: 16) {
        // Mic only (no people -- audio-only recording)
        AvatarCluster(
            people: [],
            totalCount: 0,
            size: 26,
            showLeadingRecordingAvatar: true
        )

        // Mic + one person
        AvatarCluster(
            people: [
                AvatarPerson(displayName: "Alice", email: "alice@example.com")
            ],
            totalCount: 1,
            size: 26,
            showLeadingRecordingAvatar: true
        )

        // Mic + three people + overflow
        AvatarCluster(
            people: [
                AvatarPerson(displayName: "Sam Altman", email: "sam@openai.com"),
                AvatarPerson(displayName: "Dario Amodei", email: "dario@anthropic.com"),
                AvatarPerson(displayName: "Satya Nadella", email: "satya@microsoft.com")
            ],
            totalCount: 7,
            size: 26,
            showLeadingRecordingAvatar: true
        )
    }
    .padding()
    .background(Tokens.contentBackground)
}

#Preview("RecordingAvatar") {
    HStack(spacing: 12) {
        RecordingAvatar(size: 26)
        RecordingAvatar(size: 28, stacked: true)
    }
    .padding()
    .background(Tokens.contentBackground)
}
