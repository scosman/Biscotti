#if os(macOS)
    import ApplicationServices
    import Foundation

    /// Tells whether a meeting or phone app has a call open by
    /// looking for call controls in its windows. Meeting apps (Teams by
    /// default) often join muted and don't open the microphone, so the mic
    /// alone can't say a call has started.
    public enum CallWindowProbe {
        /// Buttons that end a call.
        static let leaveLabels: Set<String> = [
            "leave", "leave call", "leave meeting", "hang up", "hangup", "end call", "end meeting", "end", "disconnect"
        ]

        /// A window with call controls has both a way to leave the call and
        /// a mute control.
        public static func hasCallControls(_ nodes: [NodeRecord]) -> Bool {
            var leave = false
            var mute = false
            for node in nodes where ["AXButton", "AXCheckBox", "AXPopUpButton", "AXMenuButton"].contains(node.role ?? "") {
                for text in [node.label, node.title].compactMap(\.self) {
                    let lowered = text.lowercased()
                    let first = lowered.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? lowered
                    if isLeave(first) { leave = true }
                    if isMute(first) { mute = true }
                }
                if leave, mute { return true }
            }
            return false
        }

        static func isLeave(_ text: String) -> Bool {
            leaveLabels.contains(text)
                || ["leave call", "leave meeting", "hang up", "end call", "end meeting"].contains { text.hasPrefix($0) }
        }

        /// "Mute mic", "Unmute", "Mute my audio"; not "Mute notifications".
        static func isMute(_ text: String) -> Bool {
            guard text.hasPrefix("mute") || text.hasPrefix("unmute") else { return false }
            return !["notification", "chat", "conversation", "channel", "thread", "tab"].contains { text.contains($0) }
        }

        /// The titles of an app's windows, and which of them show
        /// call controls right now.
        public struct Scan: Sendable, Equatable {
            public var callWindows: [String]
            public var windows: [String]
        }

        public static func scan(pid: Int32) -> Scan {
            let app = AXUIElementCreateApplication(pid)
            let reader = AXReader(maxNodes: 2500, maxDepth: 45, timeBudget: 0.4)
            var result = Scan(callWindows: [], windows: [])
            for (key, window) in AXReader.windows(of: app) {
                let title = String(key.split(separator: ":", maxSplits: 1).last ?? Substring(key))
                result.windows.append(title)
                if hasCallControls(reader.walk(window: window).nodes) {
                    result.callWindows.append(title)
                }
            }
            return result
        }

        /// Walks each window of the app, briefly, looking for call controls.
        public static func hasActiveCall(pid: Int32) -> Bool {
            let app = AXUIElementCreateApplication(pid)
            let reader = AXReader(maxNodes: 2500, maxDepth: 45, timeBudget: 0.4)
            for (_, window) in AXReader.windows(of: app) where hasCallControls(reader.walk(window: window).nodes) {
                return true
            }
            return false
        }
    }
#endif
