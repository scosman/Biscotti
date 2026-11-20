// swiftlint:disable force_try
import Foundation
import UICapture

struct NodeRecordBox {
    var path: String
    var label: String?
    var classes: [String]?

    var json: [String: Any] {
        var result: [String: Any] = ["path": path, "depth": path.split(separator: ".").count, "role": "AXGroup"]
        if let label { result["label"] = label }
        if let classes { result["domClasses"] = classes }
        return result
    }
}

/// Builds capture records the way the app writes them (as JSON lines).
enum UICaptureTestHeader {
    static func decode(_ object: [String: Any]) -> CaptureRecord {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return try! CaptureCoding.decodeLine(data)
    }

    static func make() -> [CaptureRecord] {
        [decode(["type": "header", "data": [
            "formatVersion": 1, "startedAt": "2026-11-18T15:00:00Z", "startUptime": 1000.0,
            "hostApp": "test", "macOSVersion": "test", "targets": [] as [Any]
        ] as [String: Any]])]
    }

    static func snapshot(at time: Double, nodes: [NodeRecordBox]) -> CaptureRecord {
        decode(["type": "snapshot", "data": [
            "uptime": 1000 + time, "bundleID": "app", "window": "0:Meeting",
            "nodes": nodes.map(\.json), "walkMillis": 1.0, "truncated": false
        ] as [String: Any]])
    }

    static func change(at time: Double, path: String, classes: String) -> CaptureRecord {
        decode(["type": "diff", "data": [
            "uptime": 1000 + time, "bundleID": "app", "window": "0:Meeting",
            "added": [] as [Any], "removed": [] as [Any],
            "changed": [["path": path, "fields": ["domClasses": classes]]],
            "walkMillis": 1.0
        ] as [String: Any]])
    }

    static func end(at time: Double) -> CaptureRecord {
        decode(["type": "note", "data": ["uptime": 1000 + time, "message": "session ended: stopped"] as [String: Any]])
    }
}

// swiftlint:enable force_try
