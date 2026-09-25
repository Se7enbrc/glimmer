//
//  ResourceTelemetryTests.swift
//
//  Resource lines stay comparable across sessions: a flat energy window is
//  no sample, not 0 W; the main thread gets its own line; and the
//  Mach-port reads preserve names, ordinary QoS and real-time priority.
//

import Foundation
import os
import Testing
@testable import Glimmer

struct ResourceTelemetryTests {

    /// Back-to-back samples often see no rail advance (about 1 in 5 did before
    /// the fix). Such a window must read as no sample, not a 0 W row.
    @Test(.enabled(if: IOReportSampler.shared != nil, "IOReport unavailable on this Mac"))
    func flatEnergyWindowIsNotZeroWatts() throws {
        let sampler = try #require(IOReportSampler.shared)
        sampler.beginSession()
        defer { sampler.beginSession() }
        _ = sampler.sample()
        for _ in 0..<40 {
            #expect(sampler.sample()?.packagePowerW != 0)
        }
    }

    /// The main thread stays visible even when it is idle.
    @MainActor @Test func mainThreadGetsItsOwnLine() {
        let names = ResourceTelemetry.sample().threads.map(\.name)
        #expect(names.contains("main"))
    }

    /// Mach-port reads must preserve ordinary QoS and recognize real-time
    /// priority even though applying that policy clears the requested QoS tier.
    @Test(.timeLimit(.minutes(1)))
    func machThreadReadsPreserveNamesAndQoS() async throws {
        let records = OSAllocatedUnfairLock(initialState: [ThreadRecord]())
        let release = DispatchSemaphore(value: 0)
        defer {
            release.signal()
            release.signal()
            release.signal()
        }

        await withCheckedContinuation { continuation in
            let thread = Thread {
                Self.recordAndPark(
                    name: "Glimmer.test-qos", records: records, continuation: continuation, release: release)
            }
            thread.name = "Glimmer.test-qos"
            thread.qualityOfService = .userInteractive
            thread.start()
        }

        await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "Glimmer.test-utility", qos: .utility)
            queue.async {
                pthread_setname_np("Glimmer.test-utility")
                defer { pthread_setname_np("") }
                Self.recordAndPark(
                    name: "Glimmer.test-utility", records: records, continuation: continuation, release: release)
            }
        }

        await withCheckedContinuation { continuation in
            let thread = Thread {
                let realtimeResult = Self.applyRealtimeScheduling()
                Self.recordAndPark(
                    name: "Glimmer.test-realtime", records: records, continuation: continuation,
                    release: release, realtimeResult: realtimeResult)
            }
            thread.name = "Glimmer.test-realtime"
            thread.qualityOfService = .userInteractive
            thread.start()
        }

        let parked = records.withLock { $0 }
        #expect(parked.count == 3)
        for record in parked {
            let sample = try #require(ResourceTelemetry.sampleOne(thread: record.port))
            #expect(sample.name == record.name)
            if record.name == "Glimmer.test-realtime" {
                #expect(record.realtimeResult == KERN_SUCCESS)
                #expect(sample.qos == Int(QOS_CLASS_USER_INTERACTIVE.rawValue))
            } else {
                let expectedQoS = record.name == "Glimmer.test-qos" ? QOS_CLASS_USER_INTERACTIVE : QOS_CLASS_UTILITY
                #expect(record.qos == expectedQoS)
                #expect(sample.qos == Int(record.qos.rawValue))
            }
        }
        let threads = ResourceTelemetry.sample().threads
        #expect(threads.contains {
            $0.name == "Glimmer.test-qos" && $0.qosLabel == "userInteractive"
        })
        #expect(threads.contains {
            $0.name == "Glimmer.test-realtime" && $0.qosLabel == "userInteractive"
        })
    }

    private struct ThreadRecord: Sendable {
        let name: String
        let port: mach_port_t
        let qos: qos_class_t
        let realtimeResult: kern_return_t?
    }

    private static func recordAndPark(
        name: String, records: OSAllocatedUnfairLock<[ThreadRecord]>,
        continuation: CheckedContinuation<Void, Never>, release: DispatchSemaphore,
        realtimeResult: kern_return_t? = nil
    ) {
        let port = mach_thread_self()
        // Each worker releases its own port right, after the test lets it go.
        defer { mach_port_deallocate(mach_task_self_, port) }
        let record = ThreadRecord(name: name, port: port, qos: qos_class_self(), realtimeResult: realtimeResult)
        records.withLock { $0.append(record) }
        continuation.resume()
        release.wait()
    }

    /// The pacer tick's real-time policy, applied here so the test does not
    /// touch the shared counters and log lines the tick's own copy writes.
    private static func applyRealtimeScheduling() -> kern_return_t {
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.numer != 0 else {
            return KERN_FAILURE
        }
        func toAbs(_ nanoseconds: UInt64) -> UInt32 {
            UInt32(nanoseconds * UInt64(timebase.denom) / UInt64(timebase.numer))
        }
        var policy = thread_time_constraint_policy_data_t(
            period: toAbs(4_000_000), computation: toAbs(1_000_000),
            constraint: toAbs(4_000_000), preemptible: 0)
        let count = mach_msg_type_number_t(
            MemoryLayout<thread_time_constraint_policy_data_t>.stride / MemoryLayout<integer_t>.stride)
        let port = mach_thread_self()
        defer { mach_port_deallocate(mach_task_self_, port) }
        return withUnsafeMutablePointer(to: &policy) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_policy_set(port, thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), $0, count)
            }
        }
    }
}
