// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Darwin
import Foundation

/// The condition guards the ring and lifecycle; only the owned thread calls consume.
final class AudioPacketWorker: @unchecked Sendable {
    private struct Slot {
        var bytes = [UInt8](repeating: 0, count: RtpAudioReceiver.maxPacketSize)
        var count = 0
        var arrival: UInt64 = 0
    }
    private let condition = NSCondition()
    private let lifecycleLock = NSLock()
    private var slots: [Slot]
    private var head = 0
    private var queuedCount = 0
    private var running = false
    private var stopping = false
    private let consume: @Sendable ([UInt8], UInt64) -> Void
    private let configureThread: @Sendable () -> Void

    init(capacity: Int = 64, configureThread: @escaping @Sendable () -> Void = AudioPacketWorker.configureThread,
         consume: @escaping @Sendable ([UInt8], UInt64) -> Void) {
        precondition(capacity > 0)
        slots = (0..<capacity).map { _ in Slot() }
        self.consume = consume
        self.configureThread = configureThread
    }

    func start() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        condition.lock()
        defer { condition.unlock() }
        guard !running else { return }
        stopping = false
        running = true
        let thread = Thread { [self] in run() }
        thread.name = "Glimmer.audioDecode"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Drop newest on overflow: retained packets stay ordered, and RTP/FEC sees the missing sequence.
    @discardableResult
    func enqueue(_ bytes: [UInt8], count size: Int, arrival: UInt64) -> Bool {
        bytes.withUnsafeBytes { enqueue($0, count: size, arrival: arrival) }
    }

    @discardableResult
    func enqueue(_ bytes: UnsafeRawBufferPointer, count size: Int, arrival: UInt64) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard running, !stopping, size >= 0, size <= bytes.count,
              size <= RtpAudioReceiver.maxPacketSize else { return false }
        guard queuedCount < slots.count else {
            AudioPipelineTelemetry.shared.queueOverflow.increment()
            return false
        }
        let index = (head + queuedCount) % slots.count
        for offset in 0..<size { slots[index].bytes[offset] = bytes[offset] }
        slots[index].count = size
        slots[index].arrival = arrival
        queuedCount += 1
        condition.signal()
        return true
    }

    /// Join before cleaning up the sink, so an old worker cannot decode into a reconnect's engine.
    func stop(onStopping: @Sendable () -> Void = {}) {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        requestStop()
        onStopping()
        condition.lock()
        while running { condition.wait() }
        head = 0
        queuedCount = 0
        condition.unlock()
    }

    /// Deinitialization may run on the consumer itself; cancellation must not join that thread.
    func requestStop() {
        condition.lock()
        stopping = true
        condition.broadcast()
        condition.unlock()
    }

    private func run() {
        var packet = [UInt8]()
        packet.reserveCapacity(RtpAudioReceiver.maxPacketSize)
        configureThread()
        while let arrival = take(into: &packet) {
            let now = DispatchTime.now().uptimeNanoseconds
            if !packet.isEmpty {
                AudioPipelineTelemetry.shared.queueWait.observe(Double(now &- arrival) / 1_000_000)
            }
            autoreleasepool { consume(packet, arrival) }
        }
        AudioPipelineTelemetry.shared.setRealtime(false)
        condition.lock()
        running = false
        condition.broadcast()
        condition.unlock()
    }

    private func take(into packet: inout [UInt8]) -> UInt64? {
        condition.lock()
        defer { condition.unlock() }
        while queuedCount == 0 && !stopping { condition.wait() }
        guard !stopping else { return nil }
        let size = slots[head].count
        if packet.count > size { packet.removeLast(packet.count - size) }
        while packet.count < size { packet.append(0) }
        for index in 0..<size { packet[index] = slots[head].bytes[index] }
        let arrival = slots[head].arrival
        head = (head + 1) % slots.count
        queuedCount -= 1
        return arrival
    }

    static func configureThread() {
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
}
