#if os(macOS)
    import ApplicationServices
    import Foundation

    /// Reads and switches on a meeting app's live captions
    /// through Accessibility, the way a person would click the button.
    public enum CaptionControl {
        public enum State: Sendable, Equatable {
            /// The captions panel is showing.
            case showing
            /// Off, and there's a Captions button to press.
            case hidden
            /// Off, with the captions control inside the call's More menu.
            case inMoreMenu
            /// No captions panel and no button found.
            case unknown
        }

        /// Labels of a captions panel that is open.
        static func isCaptionPanel(_ text: String) -> Bool {
            let lowered = text.lowercased()
            return lowered == "live captions" || lowered.hasPrefix("hide live captions") || lowered == "hide captions"
        }

        /// Labels of the button that turns captions on.
        static func isTurnOnButton(_ text: String) -> Bool {
            ["captions", "show captions", "show live captions", "turn on live captions", "turn on captions"]
                .contains(text.lowercased())
        }

        static let controlRoles: Set<String> = ["AXButton", "AXMenuItem", "AXCheckBox", "AXMenuButton", "AXRadioButton"]

        public static func state(pid: Int32) -> State {
            var sawButton = false
            var sawCallMore = false
            var sawLeave = false
            let found = search(pid: pid) { role, text in
                if isCaptionPanel(text) { return true }
                if role == "AXButton", isTurnOnButton(text) { sawButton = true }
                if text == "More", role == "AXPopUpButton" || role == "AXButton" { sawCallMore = true }
                if role == "AXButton", text == "Leave" { sawLeave = true }
                return false
            }
            if found != nil { return .showing }
            if sawButton { return .hidden }
            return sawCallMore && sawLeave ? .inMoreMenu : .unknown
        }

        /// Presses the Captions button. Returns false if it wasn't found or
        /// the press failed. Does nothing when captions are already on.
        @discardableResult
        public static func turnOn(pid: Int32) -> Bool {
            switch state(pid: pid) {
            case .hidden:
                guard let button = search(pid: pid, matching: { role, text in role == "AXButton" && isTurnOnButton(text) })
                else { return false }
                return press(button)
            case .inMoreMenu:
                return turnOnThroughMoreMenu(pid: pid)
            case .showing, .unknown:
                return false
            }
        }

        /// Teams keeps captions in More (sometimes under "Language and
        /// speech"). Opens the menu, finds the item, and closes the menu again
        /// if it isn't there.
        static func turnOnThroughMoreMenu(pid: Int32) -> Bool {
            guard let more = search(pid: pid, matching: { role, text in
                text == "More" && (role == "AXPopUpButton" || role == "AXButton")
            }), press(more) else { return false }
            Thread.sleep(forTimeInterval: 0.7)
            if let item = findTurnOnItem(pid: pid) { return press(item) }
            if let submenu = search(pid: pid, matching: { role, text in
                controlRoles.contains(role) && text.lowercased().hasPrefix("language and speech")
            }), press(submenu) {
                Thread.sleep(forTimeInterval: 0.7)
                if let item = findTurnOnItem(pid: pid) { return press(item) }
            }
            pressEscape(pid: pid)
            return false
        }

        static func findTurnOnItem(pid: Int32) -> AXUIElement? {
            search(pid: pid) { role, text in
                controlRoles.contains(role) && (isTurnOnButton(text) || text.lowercased().hasPrefix("turn on live captions"))
            }
        }

        static func press(_ element: AXUIElement) -> Bool {
            AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
        }

        static func pressEscape(pid: Int32) {
            for keyDown in [true, false] {
                CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: keyDown)?.postToPid(pid)
            }
        }

        /// Depth-first search of the app's windows for the first element
        /// whose role and label (title or description) match.
        static func search(pid: Int32, limit: Int = 6000, matching: (String, String) -> Bool) -> AXUIElement? {
            let app = AXUIElementCreateApplication(pid)
            var visited = 0
            for (_, window) in AXReader.windows(of: app) {
                var stack = [window]
                while let element = stack.popLast(), visited < limit {
                    visited += 1
                    let role = string(element, kAXRoleAttribute) ?? ""
                    for text in [string(element, kAXTitleAttribute), string(element, kAXDescriptionAttribute)].compactMap(\.self)
                        where matching(role, text)
                    {
                        return element
                    }
                    var children: CFTypeRef?
                    if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
                       let list = children as? [AXUIElement]
                    {
                        stack.append(contentsOf: list.reversed())
                    }
                }
            }
            return nil
        }

        static func string(_ element: AXUIElement, _ attribute: String) -> String? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
            return value as? String
        }
    }
#endif
