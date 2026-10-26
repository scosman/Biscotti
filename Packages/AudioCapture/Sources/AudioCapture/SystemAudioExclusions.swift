import CoreAudio

/// Apps whose sound is left out of the system-audio track.
///
/// The system track is a global tap (per-app capture can't follow browser
/// tabs or FaceTime; see `specs/research/audio/phase9_validation_findings.md`
/// §3), so every sound the Mac makes lands in the recording. These sources
/// never carry meeting audio but do make noise during meetings. Never list a
/// meeting app (`AudioProcess.knownMeetingBundleIDs`) or Biscotti itself: the
/// tap has to hear the permission probe's tone.
enum SystemAudioExclusions {
    /// Exact bundle IDs, as Core Audio reports them (`kAudioProcessPropertyBundleID`).
    static let bundleIDs: [String] = [
        // Notification and alert sounds for every app, and the new-mail
        // sounds of classic Outlook and Mail: Notification Center and the
        // mail clients hand them to this daemon instead of playing them.
        "systemsoundserverd",
        // Mail clients, in case a version plays a sound from its own process.
        "com.microsoft.Outlook",
        "com.apple.mail",
        // Music players.
        "com.apple.Music",
        "com.apple.podcasts",
        "com.spotify.client"
    ]

    /// The running processes to exclude, for taps that can only exclude
    /// process objects (before macOS 26).
    static func processes(in processes: [AudioProcess]) -> [AudioProcess] {
        let excluded = Set(bundleIDs)
        return processes.filter { process in
            process.bundleID.map { excluded.contains($0) } ?? false
        }
    }
}
