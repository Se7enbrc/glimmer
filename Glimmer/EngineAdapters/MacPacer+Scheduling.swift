// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import Darwin
import GlimmerEngine

extension MacPacer {
    static func prepareTickThread() {
        Diag.notice("pacer tick realtime flag = "
            + "\(PersistentStorage.defaults.bool(forKey: realtimeDefaultsKey)) "
            + "(key=\(realtimeDefaultsKey))", "Stream.Pacer")
        if PersistentStorage.defaults.bool(forKey: realtimeDefaultsKey) {
            Self.applyRealtimeScheduling()
        } else {
            // Flag off: the thread stays userInteractive, so the RT gauge is 0.
            TelemetryCounters.shared.setPacerTickRealtime(false)
        }
    }

    /// Pin the calling thread (the tick thread) to Mach THREAD_TIME_CONSTRAINT
    /// scheduling - the same real-time class CoreAudio's IO render thread uses so
    /// it can't be preempted under load. There is no QoS class above
    /// userInteractive; this is the only mechanism that reserves the thread a
    /// guaranteed slot per cadence, which is what kills the descheduled tick miss.
    /// MUST be called from inside the thread body (uses `mach_thread_self()`).
    /// Best-effort: a failed `thread_policy_set` is logged and ignored - the
    /// thread keeps running at userInteractive.
    private static func applyRealtimeScheduling() {
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.numer != 0 else {
            Diag.warn("pacer tick thread: mach_timebase_info failed; staying userInteractive", "Stream.Pacer")
            TelemetryCounters.shared.setPacerTickRealtime(false)
            return
        }
        // ns -> mach abs-time units. Conservative cadence: a ~4.0ms period covers
        // up to 240Hz so the thread gets a reserved slot often enough for any
        // panel (120/240Hz) without knowing the refresh yet; it simply skips
        // slots it doesn't need. computation is handleTick's tiny timing-capture
        // budget (it dispatches the real present off-thread). constraint = period:
        // the callback must land within the vsync. Non-preemptible - the window is
        // small enough to always complete once started.
        func toAbs(_ ns: UInt64) -> UInt32 {
            UInt32(ns * UInt64(timebase.denom) / UInt64(timebase.numer))
        }
        var policy = thread_time_constraint_policy_data_t(
            period: toAbs(4_000_000),       // 4.0ms - covers up to 240Hz
            computation: toAbs(1_000_000),  // 1.0ms - tick uses ~0.2ms; headroom
                                            // so a heavier tick can't overrun and
                                            // get demoted (it's a ceiling, not spin)
            constraint: toAbs(4_000_000),   // 4.0ms - finish within the vsync
            preemptible: 0)                 // non-preemptible (tiny window)
        // THREAD_TIME_CONSTRAINT_POLICY_COUNT is a C sizeof macro the Swift
        // overlay doesn't expose; derive the integer_t-word count from the struct.
        let count = mach_msg_type_number_t(
            MemoryLayout<thread_time_constraint_policy_data_t>.stride / MemoryLayout<integer_t>.stride)
        // mach_thread_self() returns a +1 send right; balance it so each tick-thread
        // spawn doesn't leak a thread-port reference.
        let machThread = mach_thread_self()
        defer { mach_port_deallocate(mach_task_self_, machThread) }
        let kr = withUnsafeMutablePointer(to: &policy) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_policy_set(machThread, thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY),
                                  $0, count)
            }
        }
        // Record the outcome as the queryable RT gauge (1 = RT priority, 0 = not).
        TelemetryCounters.shared.setPacerTickRealtime(kr == KERN_SUCCESS)
        if kr == KERN_SUCCESS {
            Diag.notice("pacer tick thread: realtime scheduling applied", "Stream.Pacer")
        } else {
            Diag.warn("pacer tick thread: thread_policy_set failed (kr=\(kr)); staying userInteractive", "Stream.Pacer")
        }
    }
}
