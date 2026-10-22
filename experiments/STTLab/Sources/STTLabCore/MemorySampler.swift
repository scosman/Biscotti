import Darwin
import Foundation

/// Periodically samples our process's physical footprint and (optionally) speech-related
/// system processes. Call `start()` before the work and `stop()` after to get a report.
public actor MemorySampler {
    private let interval: TimeInterval
    private let watchSystemProcesses: Bool
    private var samplingTask: Task<Void, Never>?
    private var peakFootprint: UInt64 = 0
    private var sampleCount: Int = 0
    private var systemPeaks: [Int32: (name: String, peak: UInt64)] = [:]
    private var systemNote: String?

    public init(interval: TimeInterval = 0.5, watchSystemProcesses: Bool = false) {
        self.interval = interval
        self.watchSystemProcesses = watchSystemProcesses
    }

    public func start() {
        guard samplingTask == nil else { return }
        samplingTask = Task { [interval, watchSystemProcesses] in
            while !Task.isCancelled {
                takeSample(watchSystem: watchSystemProcesses)
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    public func stop() -> MemoryReport {
        samplingTask?.cancel()
        samplingTask = nil

        let lifetimePeak = readLifetimePeakFootprint()

        let systemProcesses = systemPeaks.map { pid, entry in
            ProcessMemory(name: entry.name, pid: pid, peakFootprintBytes: entry.peak)
        }.sorted { $0.name < $1.name }

        return MemoryReport(
            processPeakFootprintBytes: peakFootprint > 0 ? peakFootprint : nil,
            processLifetimePeakBytes: lifetimePeak,
            sampleIntervalSeconds: interval,
            sampleCount: sampleCount,
            systemProcesses: systemProcesses,
            systemProcessesNote: systemNote
        )
    }

    private func takeSample(watchSystem: Bool) {
        sampleCount += 1

        // Our process footprint via task_info
        let footprint = readProcessFootprint()
        if footprint > peakFootprint {
            peakFootprint = footprint
        }

        if watchSystem {
            sampleSystemSpeechProcesses()
        }
    }

    private func sampleSystemSpeechProcesses() {
        // List all PIDs
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return }
        var pids = [Int32](repeating: 0, count: Int(count))
        let actual = proc_listallpids(&pids, Int32(pids.count) * Int32(MemoryLayout<Int32>.size))
        guard actual > 0 else { return }

        for i in 0 ..< Int(actual) {
            let pid = pids[i]
            guard pid > 0 else { continue }

            var nameBuf = [UInt8](repeating: 0, count: 256)
            nameBuf.withUnsafeMutableBufferPointer { buf in
                _ = proc_name(pid, buf.baseAddress!, UInt32(buf.count))
            }
            let name: String
            if let nullIndex = nameBuf.firstIndex(of: 0) {
                name = String(decoding: nameBuf[..<nullIndex], as: UTF8.self)
            } else {
                name = String(decoding: nameBuf, as: UTF8.self)
            }
            guard name.localizedCaseInsensitiveContains("speech") else { continue }

            var usage = rusage_info_v4()
            let result = withUnsafeMutablePointer(to: &usage) { ptr in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rusagePtr in
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, rusagePtr)
                }
            }
            if result == 0 {
                let footprint = usage.ri_phys_footprint
                if let existing = systemPeaks[pid] {
                    if footprint > existing.peak {
                        systemPeaks[pid] = (name, footprint)
                    }
                } else {
                    systemPeaks[pid] = (name, footprint)
                }
            } else {
                let errMsg = "EPERM for pid \(pid) (\(name))"
                if systemNote == nil {
                    systemNote = "unavailable: \(errMsg)"
                }
            }
        }
    }
}

// MARK: - Mach/Darwin helpers

/// Read our process's current physical footprint via task_info.
private func readProcessFootprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) { infoPtr in
        infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { ptr in
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), ptr, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return 0 }
    return UInt64(info.phys_footprint)
}

/// Read our process's lifetime peak physical footprint via task_info.
private func readLifetimePeakFootprint() -> UInt64? {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) { infoPtr in
        infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { ptr in
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), ptr, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return nil }
    return UInt64(info.ledger_phys_footprint_peak)
}
