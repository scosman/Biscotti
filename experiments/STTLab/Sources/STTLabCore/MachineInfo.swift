import Foundation

/// Hardware and OS information for the machine that ran an engine.
public struct MachineInfo: Codable, Sendable, Equatable {
    public var hostModel: String
    public var chip: String
    public var memoryBytes: UInt64
    public var osVersion: String
    public var osBuild: String

    public init(
        hostModel: String,
        chip: String,
        memoryBytes: UInt64,
        osVersion: String,
        osBuild: String
    ) {
        self.hostModel = hostModel
        self.chip = chip
        self.memoryBytes = memoryBytes
        self.osVersion = osVersion
        self.osBuild = osBuild
    }

    /// Build from the current machine's sysctl and ProcessInfo values.
    public static func current() -> MachineInfo {
        MachineInfo(
            hostModel: sysctl(name: "hw.model"),
            chip: sysctl(name: "machdep.cpu.brand_string"),
            memoryBytes: ProcessInfo.processInfo.physicalMemory,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            osBuild: sysctl(name: "kern.osversion")
        )
    }
}

private func sysctl(name: String) -> String {
    var size: Int = 0
    sysctlbyname(name, nil, &size, nil, 0)
    guard size > 0 else { return "unknown" }
    var buffer = [UInt8](repeating: 0, count: size)
    sysctlbyname(name, &buffer, &size, nil, 0)
    // Truncate at the null terminator (size includes it).
    if let nullIndex = buffer.firstIndex(of: 0) {
        buffer = Array(buffer[..<nullIndex])
    }
    return String(decoding: buffer, as: UTF8.self)
}
