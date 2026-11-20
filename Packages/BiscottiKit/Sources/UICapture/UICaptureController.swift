#if os(macOS)
    import AppKit
    import ApplicationServices
    import Automation
    import Foundation
    import MeetingCatalog
    import Observation

    /// Starts and stops UI capture sessions from the menu bar.
    ///
    /// A capture records the accessibility tree of running meeting apps
    /// (Teams, Zoom, Webex...) to a JSONL file in a folder the user picks.
    /// The files are used to tune speaker detection; nothing reads them
    /// automatically.
    @MainActor @Observable
    public final class UICaptureController {
        public private(set) var isCapturing = false
        public private(set) var startedAt: Date?
        public private(set) var currentFile: URL?
        /// Shown in the menu after a session ends or a start fails.
        public private(set) var lastMessage: String?
        /// True when the running session was started by a recording, so the
        /// recording's stop also stops it. A manual capture is left running.
        public private(set) var isTiedToRecording = false

        @ObservationIgnored private var session: CaptureSession?
        @ObservationIgnored private let defaults: UserDefaults
        @ObservationIgnored private let catalog: any MeetingCatalog
        public var schedule = CaptureSchedule()
        /// Bundle IDs of processes using the microphone right now. Browsers
        /// and Ferdium are captured only while they (or their helpers) are,
        /// since their windows also hold unrelated tabs and services.
        @ObservationIgnored public var micUsersProvider: (@MainActor () -> Set<String>)?
        /// Meeting apps the user turned off in Settings.
        @ObservationIgnored public var excludedApps: Set<String> = []
        @ObservationIgnored private var rescanTask: Task<Void, Never>?
        @ObservationIgnored private var capturedPIDs: Set<Int32> = []

        static let folderKey = "biscotti.uicapture.folder"

        public init(defaults: UserDefaults = .standard, catalog: any MeetingCatalog = BundledMeetingCatalog()) {
            self.defaults = defaults
            self.catalog = catalog
        }

        /// Folder the user chose, if any.
        public var folder: URL? {
            defaults.string(forKey: Self.folderKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
        }

        /// Where captures go when no folder was chosen.
        public static var defaultFolder: URL {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            return support.appendingPathComponent("Biscotti/ui-captures", isDirectory: true)
        }

        /// Starts a capture for a recording that just began. Never shows a
        /// dialog (it runs mid-meeting): without Accessibility permission it
        /// skips and leaves a message; with no meeting app open it does nothing.
        /// Runs for the whole recording, up to `recordingMaxDuration`.
        /// - Parameter bundleFolder: The meeting's root bundle
        ///   (the folder holding its audio). The capture is evidence for that
        ///   meeting, so it lives and is deleted with the audio.
        public func startForRecording(meetingID: UUID, startedAt: Date?, bundleFolder: URL? = nil) {
            // One event: a recording owns the capture. Anything still running
            // (an old session that never got its stop) is ended first.
            if isCapturing {
                session?.stop()
                session = nil
                isCapturing = false
            }
            guard AXIsProcessTrusted() else {
                lastMessage = "Meeting window capture skipped: Biscotti needs Accessibility permission. Use Start UI Capture once to grant it."
                return
            }
            let targets = runningMeetingApps()
            guard !targets.isEmpty else { return }
            var recordingSchedule = schedule
            recordingSchedule.maxDuration = Self.recordingMaxDuration
            if let bundleFolder {
                try? FileManager.default.createDirectory(at: bundleFolder, withIntermediateDirectories: true)
            }
            begin(
                targets: targets, folder: bundleFolder ?? folder ?? Self.defaultFolder, schedule: recordingSchedule,
                recordingMeetingID: meetingID, recordingStartedAt: startedAt
            )
            isTiedToRecording = isCapturing
        }

        /// While a recording runs, add meeting apps that start using the mic
        /// later (Ferdium or a browser joining the call) to the same capture.
        private func startRescan() {
            rescanTask?.cancel()
            rescanTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5))
                    guard let self, isCapturing, let session else { return }
                    for target in runningMeetingApps() where !capturedPIDs.contains(target.pid) {
                        capturedPIDs.insert(target.pid)
                        session.add(target)
                    }
                    // Apps that quit leave the capture. An app that only let
                    // go of the mic stays: muting in Teams releases it.
                    for pid in capturedPIDs where Self.hasExited(pid) {
                        capturedPIDs.remove(pid)
                        session.remove(pid: pid)
                    }
                }
            }
        }

        /// Stops the session if a recording started it. A capture started by
        /// hand keeps running.
        public func stopForRecording() {
            guard isTiedToRecording else { return }
            stop()
        }

        static func hasExited(_ pid: Int32) -> Bool {
            NSRunningApplication(processIdentifier: pid)?.isTerminated ?? true
        }

        /// The same 12-hour ceiling as hand-started captures.
        static let recordingMaxDuration: TimeInterval = 12 * 3600

        /// Starts a session for every running meeting app.
        /// - Parameters:
        ///   - recordingMeetingID: The Biscotti recording in progress, if any,
        ///     noted in the file so the capture can be lined up with its audio.
        public func start(recordingMeetingID: UUID? = nil, recordingStartedAt: Date? = nil) {
            guard !isCapturing else { return }
            lastMessage = nil
            guard Self.ensureAccessibilityPermission() else {
                lastMessage = "Allow Biscotti under Privacy & Security \u{2192} Accessibility, then start the capture again."
                return
            }
            let targets = runningMeetingApps()
            guard !targets.isEmpty else {
                lastMessage = "Open Teams or Zoom first. Browsers aren't captured."
                return
            }
            guard let folder = folder ?? chooseFolder() else { return }
            begin(
                targets: targets, folder: folder, schedule: schedule,
                recordingMeetingID: recordingMeetingID, recordingStartedAt: recordingStartedAt
            )
        }

        private func begin(
            targets: [TargetApp],
            folder: URL,
            schedule: CaptureSchedule,
            recordingMeetingID: UUID?,
            recordingStartedAt: Date?
        ) {
            let now = Date()
            do {
                let writer = try CaptureWriter(url: folder.appendingPathComponent(CaptureWriter.fileName(for: now)))
                let url = writer.url
                let session = CaptureSession(targets: targets, writer: writer, schedule: schedule) { [weak self] reason in
                    Task { @MainActor in self?.sessionEnded(reason: reason, url: url) }
                }
                session.start(header: SessionHeader(
                    startedAt: now,
                    startUptime: ProcessInfo.processInfo.systemUptime,
                    hostApp: Self.hostAppDescription(),
                    macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                    targets: targets,
                    recordingMeetingID: recordingMeetingID,
                    recordingStartedAt: recordingStartedAt
                ))
                self.session = session
                isCapturing = true
                startedAt = now
                currentFile = url
                // Hand-started and recording captures alike pick up meeting
                // apps that open later and drop ones that quit.
                capturedPIDs = Set(targets.map(\.pid))
                startRescan()
            } catch {
                lastMessage = "Couldn't create the capture file: \(error.localizedDescription)"
            }
        }

        public func stop() {
            rescanTask?.cancel()
            rescanTask = nil
            session?.stop()
        }

        /// Lets the user pick a different folder next time.
        public func chooseFolderAgain() {
            _ = chooseFolder()
        }

        public func revealCurrentFile() {
            if let url = currentFile ?? folder {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }

        private func sessionEnded(reason: String, url: URL) {
            // A replaced session finishing late must not clear the new one.
            guard url == currentFile else { return }
            session = nil
            isCapturing = false
            isTiedToRecording = false
            startedAt = nil
            lastMessage = "Capture saved (\(reason)): \(url.lastPathComponent)"
        }

        // MARK: - Targets

        /// Running GUI meeting apps. Browsers and Ferdium are included only
        /// while they are using the microphone (i.e. on a call).
        /// Running meeting and phone apps whose windows may
        /// hold a call. Check each with `CallWindowProbe.hasActiveCall` off
        /// the main thread. Empty without Accessibility permission.
        public func callCandidates() -> [TargetApp] {
            guard AXIsProcessTrusted() else { return [] }
            return runningMeetingApps()
        }

        func runningMeetingApps() -> [TargetApp] {
            let micUsers = micUsersProvider?() ?? []
            return NSWorkspace.shared.runningApplications.compactMap { app in
                guard app.activationPolicy == .regular,
                      let bundleID = app.bundleIdentifier,
                      catalog.isMeetingApp(bundleID: bundleID),
                      !excludedApps.contains(bundleID),
                      !(excludedApps.contains(BrowserApps.groupID) && BrowserApps.isBrowser(bundleID) && bundleID != BrowserApps.ferdium),
                      !BrowserApps.isBrowser(bundleID) || Self.isUsingMic(bundleID, micUsers: micUsers)
                else { return nil }
                let version = app.bundleURL
                    .flatMap { Bundle(url: $0) }?
                    .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                return TargetApp(
                    bundleID: bundleID,
                    name: catalog.displayName(forBundleID: bundleID) ?? app.localizedName ?? bundleID,
                    pid: app.processIdentifier,
                    version: version
                )
            }
        }

        /// The app itself or one of its helpers (`<bundleID>.helper...`) is on the mic.
        nonisolated static func isUsingMic(_ bundleID: String, micUsers: Set<String>) -> Bool {
            micUsers.contains { $0 == bundleID || $0.hasPrefix(bundleID + ".") }
        }

        // MARK: - Permission and folder

        /// At launch: if meeting capture is on and Biscotti isn't trusted
        /// (every unsigned rebuild loses the grant), show the system prompt
        /// now rather than mid-meeting.
        public static var hasAccessibilityPermission: Bool {
            AXIsProcessTrusted()
        }

        public static func openAccessibilitySettings() {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }

        public static func promptForAccessibilityIfNeeded() {
            guard !AXIsProcessTrusted() else { return }
            _ = ensureAccessibilityPermission()
        }

        /// Returns whether Biscotti is trusted; if not, shows the system
        /// prompt that opens the Accessibility settings.
        static func ensureAccessibilityPermission() -> Bool {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        }

        private func chooseFolder() -> URL? {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = "Save Captures Here"
            panel.message = "Choose a folder for UI capture files."
            guard panel.runModal() == .OK, let url = panel.url else { return nil }
            defaults.set(url.path, forKey: Self.folderKey)
            return url
        }

        private static func hostAppDescription() -> String {
            let info = Bundle.main.infoDictionary
            let version = info?["CFBundleShortVersionString"] as? String ?? "?"
            let build = info?["CFBundleVersion"] as? String ?? "?"
            return "Biscotti \(version) (\(build))"
        }
    }
#endif
