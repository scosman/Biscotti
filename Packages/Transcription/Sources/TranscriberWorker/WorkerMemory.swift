import Darwin
import os.log

/// The worker's physical footprint and the system's wired memory.
///
/// The live model's soak showed transient wired-memory spikes of unknown
/// source that the process footprint does not show
/// (`specs/research/live_transcription/README.md`), so both are logged when
/// a live model loads and unloads, for the 16 GB hardware check.
enum WorkerMemory {
    private static let log = Logger(subsystem: "net.scosman.biscotti", category: "live")

    static func log(_ moment: StaticString) {
        let footprint = footprintBytes().map { Double($0) / 1_073_741_824 } ?? -1
        let wired = systemWiredBytes().map { Double($0) / 1_073_741_824 } ?? -1
        Self.log.notice("Worker memory \(moment, privacy: .public): footprint \(footprint, format: .fixed(precision: 2), privacy: .public) GB, system wired \(wired, format: .fixed(precision: 2), privacy: .public) GB")
    }

    /// This process's physical footprint, from `proc_pid_rusage`.
    static func footprintBytes() -> UInt64? {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        return result == 0 ? usage.ri_phys_footprint : nil
    }

    /// Wired memory across the system, from `host_statistics64`. Neural
    /// Engine and GPU allocations can count here and not in the footprint.
    static func systemWiredBytes() -> UInt64? {
        let host = mach_host_self()
        var pageSize: vm_size_t = 0
        guard host_page_size(host, &pageSize) == KERN_SUCCESS else { return nil }
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        return result == KERN_SUCCESS ? UInt64(stats.wire_count) * UInt64(pageSize) : nil
    }
}
