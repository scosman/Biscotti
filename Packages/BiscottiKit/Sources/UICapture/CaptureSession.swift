#if os(macOS)
    import ApplicationServices
    import Foundation

    /// Timing for a capture session.
    public struct CaptureSchedule: Sendable {
        /// Diff snapshot cadence outside bursts.
        public var interval: TimeInterval = 2
        /// Full (non-diff) snapshot cadence, so a reader can resync.
        public var fullSnapshotInterval: TimeInterval = 60
        /// How often a high-frequency burst starts, and how long it lasts.
        /// Bursts catch level meters and highlight rings that a 2 s cadence misses.
        public var burstEvery: TimeInterval = 45
        public var burstLength: TimeInterval = 4
        public var burstInterval: TimeInterval = 0.1
        /// The session stops itself after this long.
        /// 12 hours for every capture (was 30 minutes).
        public var maxDuration: TimeInterval = 12 * 3600
        /// Accessibility notifications kept per second, per app.
        public var maxEventsPerSecond = 150

        public init() {}
    }

    /// Records one or more meeting apps' accessibility trees to a JSONL file.
    ///
    /// All Accessibility-API work runs on the session's own thread and run
    /// loop: AX calls block, and AXObserver callbacks need a run loop.
    /// Mutable state is touched only on that thread, except the stop flag,
    /// which is lock-protected. That confinement is why this is
    /// `@unchecked Sendable`.
    final class CaptureSession: @unchecked Sendable {
        private var targets: [TargetApp]
        private var pendingTargets: [TargetApp] = []
        private var lastNudgeAt: [String: Double] = [:]
        private let writer: CaptureWriter
        private let schedule: CaptureSchedule
        private let reader = AXReader()
        private let onFinish: @Sendable (String) -> Void

        private let lock = NSLock()
        private var stopRequested = false

        // Session-thread state.
        private var thread: Thread?
        private var startUptime: Double = 0
        private var lastSnapshot: [String: Snapshot] = [:]
        private var lastFullAt: [String: Double] = [:]
        private var nextSnapshotAt: Double = 0
        private var nextBurstAt: Double = 0
        private var burstUntil: Double = -1
        private var observers: [pid_t: AXObserver] = [:]
        /// Apps this session switched AXEnhancedUserInterface on for.
        private var enhancedUIApps: [pid_t: AXUIElement] = [:]
        private var pendingRemovals: Set<pid_t> = []
        /// The first write that failed; the session stops on it.
        private var writeError: String?
        private var eventWindowStart: Double = 0
        private var eventsInWindow: [String: Int] = [:]
        private var droppedEvents = 0

        init(
            targets: [TargetApp],
            writer: CaptureWriter,
            schedule: CaptureSchedule,
            onFinish: @escaping @Sendable (String) -> Void
        ) {
            self.targets = targets
            self.writer = writer
            self.schedule = schedule
            self.onFinish = onFinish
        }

        func start(header: SessionHeader) {
            let thread = Thread { [self] in run(header: header) }
            thread.name = "Biscotti UI capture"
            thread.qualityOfService = .utility
            self.thread = thread
            thread.start()
        }

        func stop() {
            lock.lock()
            stopRequested = true
            lock.unlock()
        }

        /// Adds an app that joined the call after the session started
        /// (Ferdium or a browser picking up the mic). Thread-safe.
        func add(_ target: TargetApp) {
            lock.lock()
            pendingTargets.append(target)
            lock.unlock()
        }

        /// Drops an app that quit. Thread-safe.
        func remove(pid: pid_t) {
            lock.lock()
            pendingRemovals.insert(pid)
            lock.unlock()
        }

        private func takePendingTargets() -> (added: [TargetApp], removed: Set<pid_t>) {
            lock.lock()
            defer { lock.unlock() }
            let pending = (pendingTargets, pendingRemovals)
            pendingTargets.removeAll()
            pendingRemovals.removeAll()
            return pending
        }

        private var shouldStop: Bool {
            lock.lock()
            defer { lock.unlock() }
            return stopRequested
        }

        // MARK: - Session thread

        private func run(header: SessionHeader) {
            startUptime = header.startUptime
            write(.header(header))
            AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
            for target in targets {
                prepare(target)
            }

            var reason = "stopped"
            while true {
                if shouldStop {
                    break
                }
                let now = uptime()
                if now - startUptime >= schedule.maxDuration {
                    reason = "reached the \(Int(schedule.maxDuration / 60))-minute limit"
                    break
                }
                if writer.isFull {
                    reason = "reached the file size limit"
                    break
                }
                if let writeError {
                    reason = "couldn't write the capture file (\(writeError))"
                    break
                }
                tick(now: now)
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: schedule.burstInterval))
            }
            finish(reason: reason)
        }

        private func tick(now: Double) {
            let pending = takePendingTargets()
            for pid in pending.removed {
                dropTarget(pid)
            }
            for target in pending.added where !targets.contains(where: { $0.pid == target.pid }) {
                targets.append(target)
                note("\(target.bundleID): joined the capture")
                prepare(target)
            }
            if now >= nextBurstAt {
                burstUntil = now + schedule.burstLength
                nextBurstAt = now + schedule.burstEvery
                note("burst start")
            }
            let inBurst = now < burstUntil
            guard now >= nextSnapshotAt else { return }
            nextSnapshotAt = now + (inBurst ? schedule.burstInterval : schedule.interval)
            for target in targets {
                snapshot(target, now: now)
            }
        }

        private func prepare(_ target: TargetApp) {
            let app = AXUIElementCreateApplication(target.pid)
            // Electron and Chromium apps build their web accessibility tree
            // only when an assistive app asks for it.
            let manual = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            note("\(target.bundleID): AXManualAccessibility -> \(manual.rawValue)")
            // Teams refuses AXManualAccessibility and then exposes only its
            // pop-ups, not the meeting stage, until something wakes it. The
            // enhanced flag is what Chromium treats as a screen reader.
            if manual != .success || !hasWebContent(app) {
                let enhanced = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
                if enhanced == .success, enhancedUIApps[target.pid] == nil {
                    enhancedUIApps[target.pid] = app
                    EnhancedUIOwnership.acquire(target.pid)
                }
                note("\(target.bundleID): AXEnhancedUserInterface -> \(enhanced.rawValue)")
            }
            addObserver(for: target, app: app)
        }

        private func snapshot(_ target: TargetApp, now: Double) {
            let app = AXUIElementCreateApplication(target.pid)
            for (key, window) in AXReader.windows(of: app) {
                let started = Date()
                let walk = reader.walk(window: window)
                let millis = Date().timeIntervalSince(started) * 1000
                let snap = Snapshot(
                    uptime: now, bundleID: target.bundleID, window: key,
                    nodes: walk.nodes, walkMillis: millis, truncated: walk.truncated
                )
                let windowKey = "\(target.bundleID)|\(key)"
                let fullDue = now - (lastFullAt[windowKey] ?? -.infinity) >= schedule.fullSnapshotInterval
                // A record that failed to write isn't a baseline for the next diff.
                if fullDue || lastSnapshot[windowKey] == nil {
                    guard write(.snapshot(snap)) else { return }
                    lastFullAt[windowKey] = now
                } else if let previous = lastSnapshot[windowKey] {
                    let diff = SnapshotDiffer.diff(from: previous, to: snap)
                    if !diff.isEmpty {
                        guard write(.diff(diff)) else { return }
                    }
                }
                lastSnapshot[windowKey] = snap
                wakeIfEmpty(window: window, nodes: walk.nodes, windowKey: windowKey, now: now)
            }
        }

        /// Teams builds the meeting view's accessibility tree only after focus
        /// lands inside it, so a capture can see an empty shell for a whole
        /// call. When a window with web content looks empty, focus its web
        /// document (not a control: nothing gets pressed) at most every 20 s.
        private func wakeIfEmpty(window: AXUIElement, nodes: [NodeRecord], windowKey: String, now: Double) {
            guard nodes.count < 80, nodes.contains(where: { $0.role == "AXWebArea" }),
                  now - (lastNudgeAt[windowKey] ?? -.infinity) >= 20,
                  let webArea = AXReader.firstElement(in: window, role: "AXWebArea")
            else { return }
            lastNudgeAt[windowKey] = now
            let result = AXUIElementSetAttributeValue(webArea, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            note("\(windowKey): view looked empty (\(nodes.count) nodes), focused web content -> \(result.rawValue)")
        }

        private func finish(reason: String) {
            for observer in observers.values {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
            }
            observers.removeAll()
            // Turn the flag off only if no other capture still relies on it
            // (a replacement session may have started for the same app).
            for (pid, app) in enhancedUIApps where EnhancedUIOwnership.release(pid) {
                AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
            }
            enhancedUIApps.removeAll()
            if droppedEvents > 0 {
                note("dropped \(droppedEvents) events over the rate limit")
            }
            note("session ended: \(reason)")
            writer.close()
            onFinish(reason)
        }

        // MARK: - Notifications

        static let notifications: [String] = [
            kAXValueChangedNotification, kAXTitleChangedNotification, kAXLayoutChangedNotification,
            kAXFocusedUIElementChangedNotification, kAXSelectedChildrenChangedNotification,
            kAXCreatedNotification, kAXUIElementDestroyedNotification, kAXWindowCreatedNotification,
            "AXLiveRegionChanged", "AXLiveRegionCreated", "AXElementBusyChanged"
        ]

        private func addObserver(for target: TargetApp, app: AXUIElement) {
            var observer: AXObserver?
            let callback: AXObserverCallback = { _, element, name, refcon in
                guard let refcon else { return }
                let session = Unmanaged<CaptureSession>.fromOpaque(refcon).takeUnretainedValue()
                session.handle(element: element, name: name as String, refcon: refcon)
            }
            guard AXObserverCreate(target.pid, callback, &observer) == .success, let observer else {
                note("\(target.bundleID): could not create AXObserver")
                return
            }
            // The refcon carries the session; the bundle ID is looked up by pid.
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            var registered: [String] = []
            for name in Self.notifications
                where AXObserverAddNotification(observer, app, name as CFString, refcon) == .success
            {
                registered.append(name)
            }
            CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
            observers[target.pid] = observer
            note("\(target.bundleID): observing \(registered.joined(separator: ", "))")
        }

        private func handle(element: AXUIElement, name: String, refcon _: UnsafeMutableRawPointer) {
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            let bundleID = targets.first { $0.pid == pid }?.bundleID ?? "pid:\(pid)"
            let now = uptime()
            guard admitEvent(for: bundleID, now: now) else { return }
            let values = AXReader.copyMultiple(
                element, [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute]
            )
            let role = values[kAXRoleAttribute].flatMap(AXReader.string)
            write(.event(UIEvent(
                uptime: now,
                bundleID: bundleID,
                name: name,
                role: role,
                title: TextRedactor.redact(values[kAXTitleAttribute].flatMap(AXReader.string), role: role),
                label: TextRedactor.redact(values[kAXDescriptionAttribute].flatMap(AXReader.string), role: role),
                value: TextRedactor.redact(values[kAXValueAttribute].flatMap(AXReader.string), role: role)
            )))
        }
    }

    fileprivate extension CaptureSession {
        func hasWebContent(_ app: AXUIElement) -> Bool {
            for (_, window) in AXReader.windows(of: app) {
                let shallow = AXReader(maxNodes: 400, maxDepth: 12, timeBudget: 0.3).walk(window: window)
                if shallow.nodes.contains(where: { $0.role == "AXWebArea" }) {
                    return true
                }
            }
            return false
        }

        func admitEvent(for bundleID: String, now: Double) -> Bool {
            if now - eventWindowStart >= 1 {
                eventWindowStart = now
                eventsInWindow.removeAll()
            }
            let count = eventsInWindow[bundleID, default: 0]
            guard count < schedule.maxEventsPerSecond else {
                droppedEvents += 1
                return false
            }
            eventsInWindow[bundleID] = count + 1
            return true
        }

        // MARK: - Helpers

        func uptime() -> Double {
            ProcessInfo.processInfo.systemUptime
        }

        func note(_ message: String) {
            write(.note(Note(uptime: uptime(), message: message)))
        }

        /// Writes a record; false (and the session stops) if it couldn't.
        @discardableResult
        func write(_ record: CaptureRecord) -> Bool {
            guard writeError == nil else { return false }
            do {
                try writer.write(record)
                return true
            } catch {
                writeError = error.localizedDescription
                return false
            }
        }

        /// Stops watching an app that quit.
        func dropTarget(_ pid: pid_t) {
            guard let index = targets.firstIndex(where: { $0.pid == pid }) else { return }
            note("\(targets[index].bundleID): left the capture")
            targets.remove(at: index)
            if let observer = observers.removeValue(forKey: pid) {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
            }
            if enhancedUIApps.removeValue(forKey: pid) != nil {
                EnhancedUIOwnership.release(pid)
            }
        }
    }

    /// Which captures rely on an app's AXEnhancedUserInterface flag. Two
    /// sessions can overlap for a moment (a recording's capture replacing a
    /// hand-started one); the flag goes off only when the last one finishes.
    enum EnhancedUIOwnership {
        private static let lock = NSLock()
        private nonisolated(unsafe) static var owners: [pid_t: Int] = [:]

        static func acquire(_ pid: pid_t) {
            lock.lock()
            owners[pid, default: 0] += 1
            lock.unlock()
        }

        /// True when no capture relies on the flag any more.
        @discardableResult
        static func release(_ pid: pid_t) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            let remaining = max((owners[pid] ?? 1) - 1, 0)
            owners[pid] = remaining == 0 ? nil : remaining
            return remaining == 0
        }
    }
#endif
