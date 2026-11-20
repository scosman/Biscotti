#if os(macOS)
    import ApplicationServices
    import CoreText
    import Foundation

    /// Reads accessibility trees from another app into `NodeRecord`s.
    ///
    /// Nothing here looks for a specific element or path: it records every
    /// element generically (role, labels, DOM classes, frame, font weight)
    /// within node, depth and time budgets, so a Teams or Zoom UI change
    /// costs nothing at capture time.
    struct AXReader {
        var maxNodes = 6000
        var maxDepth = 60
        var timeBudget: TimeInterval = 1.5

        static let batchAttributes: [String] = [
            kAXRoleAttribute, kAXSubroleAttribute, kAXRoleDescriptionAttribute,
            kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute,
            kAXIdentifierAttribute, "AXDOMIdentifier", "AXDOMClassList",
            kAXPositionAttribute, kAXSizeAttribute,
            kAXSelectedAttribute, kAXFocusedAttribute, kAXEnabledAttribute,
            kAXMinValueAttribute, kAXMaxValueAttribute, kAXChildrenAttribute
        ]

        /// Walks one window. Returns the nodes and whether a budget cut the walk short.
        func walk(window: AXUIElement) -> (nodes: [NodeRecord], truncated: Bool) {
            let deadline = Date().addingTimeInterval(timeBudget)
            var nodes: [NodeRecord] = []
            var stack: [PendingNode] = [PendingNode(element: window, path: "0", depth: 0, inCaptions: false, index: 0)]
            var truncated = false
            while let item = stack.popLast() {
                if nodes.count >= maxNodes || Date() > deadline {
                    truncated = true
                    break
                }
                // Caption words are kept whole (root bundle
                // evidence); everything else goes through the redactor.
                let keepText = item.inCaptions && item.index != 0
                let (record, children) = read(item.element, path: item.path, depth: item.depth, keepText: keepText)
                let captions = item.inCaptions || TextRedactor.isCaptionArea(record)
                nodes.append(record)
                guard item.depth < maxDepth else {
                    truncated = truncated || !children.isEmpty
                    continue
                }
                // Push in reverse so children are visited in order.
                for (index, child) in children.enumerated().reversed() {
                    stack.append(PendingNode(
                        element: child, path: "\(item.path).\(index)", depth: item.depth + 1,
                        inCaptions: captions, index: index
                    ))
                }
            }
            return (nodes, truncated)
        }

        /// An element waiting to be read during a walk.
        private struct PendingNode {
            let element: AXUIElement
            let path: String
            let depth: Int
            /// Inside a live-captions panel.
            let inCaptions: Bool
            /// Position among its parent's children.
            let index: Int
        }

        /// Reads one element's attributes in a single batched call.
        func read(_ element: AXUIElement, path: String, depth: Int, keepText: Bool = false) -> (NodeRecord, [AXUIElement]) {
            var record = NodeRecord(path: path, depth: depth)
            let values = Self.copyMultiple(element, Self.batchAttributes)
            func value(_ name: String) -> CFTypeRef? {
                values[name]
            }

            let role = value(kAXRoleAttribute).flatMap(Self.string)
            record.role = role
            record.subrole = value(kAXSubroleAttribute).flatMap(Self.string)
            record.roleDescription = TextRedactor.redact(value(kAXRoleDescriptionAttribute).flatMap(Self.string), role: nil)
            let isCaptionText = keepText && role == kAXStaticTextRole as String
            record.title = isCaptionText ? value(kAXTitleAttribute).flatMap(Self.string)
                : TextRedactor.redact(value(kAXTitleAttribute).flatMap(Self.string), role: role)
            record.label = TextRedactor.redact(value(kAXDescriptionAttribute).flatMap(Self.string), role: role)
            record.value = isCaptionText ? value(kAXValueAttribute).flatMap(Self.string)
                : TextRedactor.redact(value(kAXValueAttribute).flatMap(Self.string), role: role)
            record.help = TextRedactor.redact(value(kAXHelpAttribute).flatMap(Self.string), role: nil)
            record.identifier = value(kAXIdentifierAttribute).flatMap(Self.string)
            record.domID = value("AXDOMIdentifier").flatMap(Self.string)
            record.domClasses = value("AXDOMClassList").flatMap(Self.stringArray)
            record.frame = Self.frame(position: value(kAXPositionAttribute), size: value(kAXSizeAttribute))
            record.selected = value(kAXSelectedAttribute).flatMap(Self.bool)
            record.focused = value(kAXFocusedAttribute).flatMap(Self.bool)
            record.enabled = value(kAXEnabledAttribute).flatMap(Self.bool)
            record.minValue = value(kAXMinValueAttribute).flatMap(Self.double)
            record.maxValue = value(kAXMaxValueAttribute).flatMap(Self.double)

            let children = value(kAXChildrenAttribute).flatMap { $0 as? [AXUIElement] } ?? []
            record.childCount = children.isEmpty ? nil : children.count

            if role == kAXStaticTextRole as String || role == kAXButtonRole as String {
                (record.bold, record.fontWeight) = Self.fontTraits(element)
            }
            return (record, children)
        }

        /// Breadth-first search for the first element with `role`.
        static func firstElement(in root: AXUIElement, role: String, limit: Int = 400) -> AXUIElement? {
            var queue = [root]
            var visited = 0
            while !queue.isEmpty, visited < limit {
                let element = queue.removeFirst()
                visited += 1
                var raw: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &raw) == .success,
                   (raw as? String) == role
                {
                    return element
                }
                var children: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
                   let list = children as? [AXUIElement]
                {
                    queue.append(contentsOf: list)
                }
            }
            return nil
        }

        /// The app's windows, with a stable key for each.
        static func windows(of app: AXUIElement) -> [(key: String, element: AXUIElement)] {
            var raw: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw) == .success,
                  let windows = raw as? [AXUIElement]
            else { return [] }
            return windows.enumerated().map { index, window in
                var title: CFTypeRef?
                AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
                let name = TextRedactor.redact(title.flatMap(string), role: nil) ?? "untitled"
                return ("\(index):\(name)", window)
            }
        }

        // MARK: - Attribute conversion

        static func copyMultiple(_ element: AXUIElement, _ names: [String]) -> [String: CFTypeRef] {
            var raw: CFArray?
            let result = AXUIElementCopyMultipleAttributeValues(
                element, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &raw
            )
            guard result == .success, let array = raw as? [CFTypeRef], array.count == names.count else {
                return [:]
            }
            var values: [String: CFTypeRef] = [:]
            for (name, item) in zip(names, array) where !isAXError(item) {
                values[name] = item
            }
            return values
        }

        /// Missing attributes come back as an AXValue wrapping an AXError.
        static func isAXError(_ item: CFTypeRef) -> Bool {
            guard CFGetTypeID(item) == AXValueGetTypeID() else { return false }
            // swiftlint:disable:next force_cast
            return AXValueGetType(item as! AXValue) == .axError
        }

        static func string(_ item: CFTypeRef) -> String? {
            if let text = item as? String {
                return text
            }
            if let number = item as? NSNumber {
                return number.stringValue
            }
            if let attributed = item as? NSAttributedString {
                return attributed.string
            }
            if let url = item as? URL {
                return url.absoluteString
            }
            return nil
        }

        static func stringArray(_ item: CFTypeRef) -> [String]? {
            guard let array = item as? [Any] else { return nil }
            let strings = array.compactMap { $0 as? String }
            return strings.isEmpty ? nil : strings
        }

        static func bool(_ item: CFTypeRef) -> Bool? {
            (item as? NSNumber)?.boolValue
        }

        static func double(_ item: CFTypeRef) -> Double? {
            (item as? NSNumber)?.doubleValue
        }

        static func frame(position: CFTypeRef?, size: CFTypeRef?) -> [Int]? {
            guard let position, let size,
                  CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
            else { return nil }
            var point = CGPoint.zero
            var extent = CGSize.zero
            // swiftlint:disable force_cast
            guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
                  AXValueGetValue(size as! AXValue, .cgSize, &extent)
            else { return nil }
            // swiftlint:enable force_cast
            return [Int(point.x), Int(point.y), Int(extent.width), Int(extent.height)]
        }

        /// Bold trait and weight of the element's text, read from its
        /// attributed string. Web content and native text both expose a font
        /// dictionary here when the app supports it; nil when it doesn't.
        static func fontTraits(_ element: AXUIElement) -> (Bool?, Double?) {
            var countRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                element, kAXNumberOfCharactersAttribute as CFString, &countRef
            ) == .success,
                let count = (countRef as? NSNumber)?.intValue, count > 0
            else { return (nil, nil) }

            var range = CFRange(location: 0, length: min(count, 200))
            guard let rangeValue = AXValueCreate(.cfRange, &range) else { return (nil, nil) }
            var attributedRef: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(
                element,
                kAXAttributedStringForRangeParameterizedAttribute as CFString,
                rangeValue,
                &attributedRef
            ) == .success,
                let attributed = attributedRef as? NSAttributedString, attributed.length > 0
            else { return (nil, nil) }

            // kAXFontTextAttribute and its keys import as Unmanaged<CFString>,
            // so the documented string values are used directly.
            let fontInfo = attributed.attribute(
                NSAttributedString.Key("AXFont"), at: 0, effectiveRange: nil
            ) as? [String: Any]
            guard let name = fontInfo?["AXFontName"] as? String else { return (nil, nil) }
            let size = (fontInfo?["AXFontSize"] as? NSNumber)?.doubleValue ?? 13
            return (isBoldName(name), weight(fontName: name, size: size))
        }

        static func isBoldName(_ name: String) -> Bool {
            let lowered = name.lowercased()
            return ["bold", "semibold", "demibold", "heavy", "black"].contains { lowered.contains($0) }
        }

        /// Core Text weight trait (-1.0 to 1.0, regular is 0, bold about 0.4),
        /// when the font resolves on this Mac. Core Text is safe off the main thread.
        static func weight(fontName: String, size: Double) -> Double? {
            let font = CTFontCreateWithName(fontName as CFString, size, nil)
            // CTFontCreateWithName falls back to a default font for unknown names.
            guard (CTFontCopyPostScriptName(font) as String) == fontName else { return nil }
            let traits = CTFontCopyTraits(font) as NSDictionary
            return (traits[kCTFontWeightTrait] as? NSNumber)?.doubleValue
        }
    }
#endif
