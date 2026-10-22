import Foundation

/// Memory measurement report from a MemorySampler run.
public struct MemoryReport: Codable, Sendable, Equatable {
    public var processPeakFootprintBytes: UInt64?
    public var processLifetimePeakBytes: UInt64?
    public var sampleIntervalSeconds: Double
    public var sampleCount: Int
    public var systemProcesses: [ProcessMemory]
    public var systemProcessesNote: String?

    public init(
        processPeakFootprintBytes: UInt64? = nil,
        processLifetimePeakBytes: UInt64? = nil,
        sampleIntervalSeconds: Double,
        sampleCount: Int,
        systemProcesses: [ProcessMemory] = [],
        systemProcessesNote: String? = nil
    ) {
        self.processPeakFootprintBytes = processPeakFootprintBytes
        self.processLifetimePeakBytes = processLifetimePeakBytes
        self.sampleIntervalSeconds = sampleIntervalSeconds
        self.sampleCount = sampleCount
        self.systemProcesses = systemProcesses
        self.systemProcessesNote = systemProcessesNote
    }
}

/// Memory of a single system process observed during sampling.
public struct ProcessMemory: Codable, Sendable, Equatable {
    public var name: String
    public var pid: Int32
    public var peakFootprintBytes: UInt64
    public var lifetimeMaxFootprintBytes: UInt64?

    public init(
        name: String,
        pid: Int32,
        peakFootprintBytes: UInt64,
        lifetimeMaxFootprintBytes: UInt64? = nil
    ) {
        self.name = name
        self.pid = pid
        self.peakFootprintBytes = peakFootprintBytes
        self.lifetimeMaxFootprintBytes = lifetimeMaxFootprintBytes
    }
}
