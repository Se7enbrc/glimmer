//
//  MacSystemStats.swift
//
//  Read host-Mac vitals (battery, CPU, RAM) for the in-stream stats overlay.
//  Built on the public sandbox-safe APIs: IOPS for battery, Mach
//  `host_statistics`/`host_statistics64` for CPU + RAM. GPU usage is NOT
//  surfaced here — the only path on macOS is IOReport/IOAccelerator
//  registry walking, which is technically reachable from a sandboxed app
//  but needs more careful entitlement / fallback work. Future: GPU.
//

import Darwin
import Foundation
import IOKit.ps
import os

/// Snapshot of host-Mac vitals at one point in time. All fields are
/// optional so a probe failure surfaces as `nil` → em-dash in the overlay,
/// not zero (which would render as "0%" and look like a degraded state).
public struct MacSystemStatsSnapshot: Sendable, Equatable {
    /// Battery percentage (0-100). nil on desktops with no battery.
    public var batteryPercent: Int?
    /// True if AC is plugged in. Drives the "charging" vs "discharging"
    /// glyph in the overlay row.
    public var batteryCharging: Bool?
    /// CPU usage 0-100, sum across all cores normalized to 100% =
    /// "all cores fully busy". Activity Monitor's "User + System" line.
    public var cpuPercent: Double?
    /// RAM usage 0-100. (active + wired + compressed) / total — matches
    /// Activity Monitor's "Memory Used" percentage.
    public var ramPercent: Double?
}

/// Sampler. Holds the previous CPU tick counts so each `snapshot()` call
/// returns a *delta-based* CPU percent rather than a since-boot integral.
/// Singleton-style — the stats timer in StreamSession is the only caller
/// per active stream session and we want CPU sampling to be continuous
/// across snapshots, not reset every probe.
@MainActor
public final class MacSystemStats {
    public static let shared = MacSystemStats()

    /// Snapshot of the four HOST_CPU_LOAD_INFO tick counters we diff between
    /// snapshots to derive a window-relative CPU busy percent.
    private struct CPUTicks {
        let user: UInt32
        let system: UInt32
        let nice: UInt32
        let idle: UInt32
    }

    private let log = Logger(subsystem: "io.ugfugl.Glimmer", category: "MacSystemStats")
    private var lastCPUTicks: CPUTicks?

    private init() {}

    public func snapshot() -> MacSystemStatsSnapshot {
        MacSystemStatsSnapshot(
            batteryPercent: batteryPercentSnapshot(),
            batteryCharging: batteryChargingSnapshot(),
            cpuPercent: cpuPercentSnapshot(),
            ramPercent: ramPercentSnapshot()
        )
    }

    // MARK: - Battery

    /// Walks IOPSCopyPowerSourcesInfo for the first source that has a
    /// percentage. Returns nil on Macs with no battery (Mac Studio, Mac
    /// mini, Mac Pro) — the caller treats nil as "no row to render".
    private func batteryPercentSnapshot() -> Int? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue()
                    as? [String: Any] else { continue }
            if let capacity = desc[kIOPSCurrentCapacityKey] as? Int,
               let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 {
                return Int((Double(capacity) / Double(max) * 100).rounded())
            }
        }
        return nil
    }

    /// True when AC power is providing energy (charging or topped off);
    /// false when running on battery. Nil if no power source could be
    /// queried at all (extremely rare). The overlay shows "charging" /
    /// "discharging" off this flag.
    private func batteryChargingSnapshot() -> Bool? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue()
                    as? [String: Any] else { continue }
            if let state = desc[kIOPSPowerSourceStateKey] as? String {
                // kIOPSACPowerValue when plugged in (charging or full),
                // kIOPSBatteryPowerValue otherwise.
                return state == (kIOPSACPowerValue as String)
            }
        }
        return nil
    }

    // MARK: - CPU

    /// Per-call CPU% based on the tick-count delta since the previous
    /// snapshot. First call returns nil (no baseline to diff against);
    /// every subsequent call returns the busy% over the elapsed window.
    /// Uses `host_statistics` HOST_CPU_LOAD_INFO which is what
    /// `top(1)` and Activity Monitor use.
    private func cpuPercentSnapshot() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size /
                                            MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPtr in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, reboundPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            log.warning("host_statistics(HOST_CPU_LOAD_INFO) failed: \(result, privacy: .public)")
            return nil
        }
        let user = info.cpu_ticks.0
        let system = info.cpu_ticks.1
        let idle = info.cpu_ticks.2
        let nice = info.cpu_ticks.3
        defer { lastCPUTicks = CPUTicks(user: user, system: system, nice: nice, idle: idle) }
        guard let last = lastCPUTicks else { return nil }
        let dUser = Double(user &- last.user)
        let dSystem = Double(system &- last.system)
        let dNice = Double(nice &- last.nice)
        let dIdle = Double(idle &- last.idle)
        let total = dUser + dSystem + dNice + dIdle
        guard total > 0 else { return nil }
        let busy = dUser + dSystem + dNice
        return (busy / total) * 100.0
    }

    // MARK: - RAM

    /// RAM usage percent. The numerator is "actually in use" memory:
    /// active + wired + compressed pages. Free + inactive + speculative
    /// are available to other processes. Matches Activity Monitor's
    /// "Memory Used" line and `vm_stat`'s active+wired+compressed sum.
    private func ramPercentSnapshot() -> Double? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size /
                                            MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, reboundPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            log.warning("host_statistics64(HOST_VM_INFO64) failed: \(result, privacy: .public)")
            return nil
        }
        // 16KB page size on Apple Silicon, 4KB on Intel. host_page_size
        // returns the live value.
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        guard pageSize > 0 else { return nil }
        let used = (UInt64(stats.active_count)
                    + UInt64(stats.wire_count)
                    + UInt64(stats.compressor_page_count))
                    * UInt64(pageSize)
        // Physical RAM via sysctl hw.memsize — gives total installed RAM
        // in bytes, the denominator for the percent calc.
        var totalRAM: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        if sysctlbyname("hw.memsize", &totalRAM, &size, nil, 0) != 0 || totalRAM == 0 {
            return nil
        }
        return (Double(used) / Double(totalRAM)) * 100.0
    }
}
