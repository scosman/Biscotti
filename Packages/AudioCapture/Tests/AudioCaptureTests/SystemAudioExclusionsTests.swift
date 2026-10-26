import CoreAudio
import Testing
@testable import AudioCapture

@Suite("SystemAudioExclusions")
struct SystemAudioExclusionsTests {
    @Test("notification sounds and Outlook are excluded")
    func noiseSourcesExcluded() {
        #expect(SystemAudioExclusions.bundleIDs.contains("systemsoundserverd"))
        #expect(SystemAudioExclusions.bundleIDs.contains("com.microsoft.Outlook"))
    }

    @Test("no meeting app is excluded")
    func meetingAppsNeverExcluded() {
        #expect(Set(SystemAudioExclusions.bundleIDs).isDisjoint(with: AudioProcess.knownMeetingBundleIDs))
    }

    /// The permission probe plays its tone from Biscotti's own process, and
    /// the system tap has to hear it.
    @Test("Biscotti is not excluded")
    func biscottiNotExcluded() {
        let ownIDs = SystemAudioExclusions.bundleIDs.filter {
            $0.hasPrefix("com.synderys.biscotti") || $0.hasPrefix("net.scosman.biscotti")
        }
        #expect(ownIDs.isEmpty)
    }

    @Test("picks only running processes whose bundle ID matches exactly")
    func picksMatchingProcesses() {
        let processes = [
            process(1, "com.microsoft.Outlook"),
            process(2, "com.microsoft.teams2"),
            process(3, "systemsoundserverd"),
            process(4, nil),
            process(5, "com.microsoft.Outlook.helper")
        ]
        #expect(SystemAudioExclusions.processes(in: processes).map(\.id) == [1, 3])
    }

    private func process(_ id: AudioObjectID, _ bundleID: String?) -> AudioProcess {
        AudioProcess(id: id, bundleID: bundleID, pid: pid_t(id), isRunningInput: false, isRunningOutput: true)
    }
}
