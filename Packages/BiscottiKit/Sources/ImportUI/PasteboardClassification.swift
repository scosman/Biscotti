import AppKit
import AudioImport
import Foundation

/// Describes one dragged item from the pasteboard, for testable classification.
public struct DraggedItemDescriptor: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case file(URL)
        /// A promised file. `typeIdentifier` is the declared type from
        /// `NSFilePromiseReceiver.fileTypes`, if available. `index` is
        /// the receiver's position in the pasteboard's promise list.
        case promise(typeIdentifier: String?, index: Int)
    }

    public let kind: Kind

    public init(kind: Kind) {
        self.kind = kind
    }
}

/// Result of classifying a drag pasteboard. Bundles descriptors with the
/// promise receivers they reference so callers don't re-read the pasteboard.
public struct PasteboardClassification {
    public let descriptors: [DraggedItemDescriptor]

    /// The `NSFilePromiseReceiver` objects read from the pasteboard. Descriptor
    /// indices refer into this array.
    public let promiseReceivers: [NSFilePromiseReceiver]
}

/// Classifies drag pasteboard items into file-URL and promise descriptors,
/// then maps each to a supported/unsupported flag via `ImportFileClassifier`.
public enum PasteboardClassifier {
    /// Walks `pasteboard.pasteboardItems` and returns descriptors together
    /// with the promise receivers they reference. Items that are neither file
    /// URLs nor promise items are skipped.
    public static func classify(
        _ pasteboard: NSPasteboard
    ) -> PasteboardClassification {
        guard let items = pasteboard.pasteboardItems else {
            return PasteboardClassification(
                descriptors: [], promiseReceivers: []
            )
        }

        // Read all promise receivers once so callers don't need to re-read.
        let receivers = pasteboard.readObjects(
            forClasses: [NSFilePromiseReceiver.self],
            options: nil
        ) as? [NSFilePromiseReceiver] ?? []
        var nextReceiverIndex = 0

        let promiseTypes = Set(
            NSFilePromiseReceiver.readableDraggedTypes.map {
                NSPasteboard.PasteboardType($0)
            }
        )

        var result: [DraggedItemDescriptor] = []

        for item in items {
            let itemTypes = Set(item.types)
            let hasPromise = !itemTypes.isDisjoint(with: promiseTypes)

            // 1. File URL?
            if let urlString = item.string(forType: .fileURL),
               let url = URL(string: urlString),
               url.isFileURL
            {
                // Consume the paired receiver so later promise-only items
                // don't pick up this item's receiver.
                if hasPromise, nextReceiverIndex < receivers.count {
                    nextReceiverIndex += 1
                }
                result.append(DraggedItemDescriptor(kind: .file(url)))
                continue
            }

            // 2. File promise?
            if hasPromise,
               nextReceiverIndex < receivers.count
            {
                let receiver = receivers[nextReceiverIndex]
                let typeID = receiver.fileTypes.first
                result.append(
                    DraggedItemDescriptor(
                        kind: .promise(
                            typeIdentifier: typeID,
                            index: nextReceiverIndex
                        )
                    )
                )
                nextReceiverIndex += 1
                continue
            }

            // 3. Neither file URL nor promise -- skip (text, link, image data).
        }

        return PasteboardClassification(
            descriptors: result, promiseReceivers: receivers
        )
    }

    /// Convenience: returns only descriptors (no receivers needed).
    /// Use `classify(_:)` when you also need the receivers.
    public static func describe(
        _ pasteboard: NSPasteboard
    ) -> [DraggedItemDescriptor] {
        classify(pasteboard).descriptors
    }

    /// Maps descriptors to support flags. `true` = supported by `ImportFileClassifier`.
    public static func supportedFlags(
        _ items: [DraggedItemDescriptor]
    ) -> [Bool] {
        items.map { descriptor in
            switch descriptor.kind {
            case let .file(url):
                ImportFileClassifier.isSupported(fileURL: url)
            case let .promise(typeIdentifier, _):
                if let id = typeIdentifier {
                    ImportFileClassifier.isSupported(typeIdentifier: id)
                } else {
                    // Unknown type -- treat as unsupported during hover.
                    false
                }
            }
        }
    }
}
