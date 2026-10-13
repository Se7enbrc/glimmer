// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import Darwin
import Foundation

enum MacTransport {
    static func configureAudioThread() {
        pthread_setname_np("Glimmer.audioDecode")
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.numer != 0 else {
            Diag.warn("audio decode thread: no Mach timebase; staying userInteractive", "Stream.Audio")
            return
        }
        func ticks(_ nanos: UInt64) -> UInt32 {
            UInt32(nanos * UInt64(timebase.denom) / UInt64(timebase.numer))
        }
        // Packet arrivals have their own 5 ms deadline, independent of the device render interval.
        // Reserve a best-effort 1 ms decode budget, as the pacer does; joining the device workgroup
        // would incorrectly claim this asynchronous producer shares its render deadline.
        var policy = thread_time_constraint_policy_data_t(
            period: ticks(5_000_000), computation: ticks(1_000_000),
            constraint: ticks(5_000_000), preemptible: 1)
        let count = mach_msg_type_number_t(
            MemoryLayout<thread_time_constraint_policy_data_t>.stride / MemoryLayout<integer_t>.stride)
        let thread = mach_thread_self()
        defer { mach_port_deallocate(mach_task_self_, thread) }
        let result = withUnsafeMutablePointer(to: &policy) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_policy_set(thread, thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), $0, count)
            }
        }
        AudioPipelineTelemetry.shared.setRealtime(result == KERN_SUCCESS)
        if result == KERN_SUCCESS {
            Diag.notice("audio decode thread: realtime scheduling applied (5 ms period, 1 ms budget)", "Stream.Audio")
        } else {
            Diag.warn("audio decode thread: thread_policy_set failed (kr=\(result)); "
                + "staying userInteractive", "Stream.Audio")
        }
    }
    static func configureInputThread() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        func ticks(_ nanos: UInt64) -> UInt32 {
            UInt32(nanos * UInt64(timebase.denom) / UInt64(timebase.numer))
        }
        // A bounded, preemptible budget; blocking between requests returns unused CPU to macOS.
        var policy = thread_time_constraint_policy_data_t(
            period: ticks(4_000_000), computation: ticks(1_000_000),
            constraint: ticks(4_000_000), preemptible: 1)
        let count = mach_msg_type_number_t(MemoryLayout.size(ofValue: policy) / MemoryLayout<integer_t>.size)
        let port = mach_thread_self()
        defer { mach_port_deallocate(mach_task_self_, port) }
        let result = withUnsafeMutablePointer(to: &policy) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_policy_set(port, thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), $0, count)
            }
        }
        if result == KERN_SUCCESS {
            Diag.notice("input send thread: realtime scheduling applied", "NativeConnection")
        } else {
            Diag.warn("input send thread: thread_policy_set failed (kr=\(result)); staying userInteractive",
                      "NativeConnection")
        }
    }
    static let receiveBatch: TransportPlatform.ReceiveBatch? =
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "recvmsg_x")
            .map { unsafeBitCast($0, to: TransportPlatform.ReceiveBatch.self) }

    static func makeBackend() -> NativeBackend {
        var platform = TransportPlatform(receiveBatch: receiveBatch,
            configureAudioThread: configureAudioThread, configureInputThread: configureInputThread)
        platform.steadyPingInterval = { EnvSignalController.shared.steadyPingInterval() }
        platform.audioPingStarted = { EnvSignalController.shared.noteAudioPingLoopStart() }
        platform.videoPingStarted = { EnvSignalController.shared.noteVideoPingLoopStart() }
        platform.audioPings = EnvSignalController.shared.audioPingsSentTotal
        platform.videoPings = EnvSignalController.shared.videoPingsSentTotal
        return NativeBackend(platform: platform)
    }
}
