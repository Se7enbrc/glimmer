//
//  ProcessMetrics.swift
//
//  The process-level CPU% / thread-count sampler the 1Hz telemetry exporter
//  reads (plus the thermal-state ordinal). Split out of
//  TelemetryExporter+RenderNDJSON.swift - pure move, the same file-split idiom
//  as the rest of the telemetry unit - to keep that file under the length
//  budget once the cadence-lock fields landed on the NDJSON row.
//

import Darwin
import Foundation

/// Process-level CPU% (sum of thread CPU usage, in percent of one core) + live
/// thread count, via the Mach task threads port. Sampled at 1Hz from the
/// exporter - cheap (one `task_threads` + per-thread `thread_info`); not on any
/// hot path. Mirrors the approach `MacSystemStats` uses for system CPU but
/// scoped to THIS process so the rig measures Glimmer's own footprint.
enum ProcessMetrics {

    /// Map `ProcessInfo.ThermalState` to a 0...3 ordinal (nominal/fair/serious/
    /// critical) so it plots as a gauge and a Grafana threshold (≥2 = serious) is
    /// trivial. Unknown future cases map to 0 (nominal) defensively.
    static func thermalOrdinal(_ state: ProcessInfo.ThermalState) -> Int {
        switch state {
        case .nominal: return 0
        case .fair: return 1
        case .serious: return 2
        case .critical: return 3
        @unknown default: return 0
        }
    }

    /// One CPU% + thread-count sample for the current process.
    static func sample() -> (cpuPercent: Double, threadCount: Int) {
        var threadList: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        let kr = task_threads(mach_task_self_, &threadList, &threadCount)
        guard kr == KERN_SUCCESS, let threads = threadList else {
            return (0, 0)
        }
        defer {
            // Release the thread port rights + the array allocation.
            for index in 0..<Int(threadCount) {
                mach_port_deallocate(mach_task_self_, threads[index])
            }
            vm_deallocate(mach_task_self_,
                          vm_address_t(UInt(bitPattern: threads)),
                          vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride))
        }

        // THREAD_BASIC_INFO_COUNT is a C macro (struct size in integer_t units),
        // not bridged to Swift - derive it from the type layout.
        let basicInfoCount = mach_msg_type_number_t(
            MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        var totalCpu: Double = 0
        for index in 0..<Int(threadCount) {
            var info = thread_basic_info()
            var count = basicInfoCount
            let infoResult = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    thread_info(threads[index], thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
                }
            }
            if infoResult == KERN_SUCCESS, (info.flags & TH_FLAGS_IDLE) == 0 {
                totalCpu += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100.0
            }
        }
        return (totalCpu, Int(threadCount))
    }
}
