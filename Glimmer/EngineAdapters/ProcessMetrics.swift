// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import Darwin

// Own-process CPU and thread count use task_threads/thread_info at the existing 1 Hz capture cadence.
// These Mach probes stay off the media paths and outside the engine.
enum ProcessMetrics {

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
