// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

/// One thread's resource line for the per-thread CPU / QoS view. `cpuPercent` is
/// percent of one core (matching `ProcessMetrics`); `qos` is the thread's QoS
/// class INTENT (the P-vs-E tier the scheduler honours); `name` is our own thread
/// label so the hot line is self-describing.
@usableFromInline package struct ThreadResourceSample: Sendable {

    @usableFromInline package init(
        name: String,
        tid: UInt64,
        cpuPercent: Double,
        qos: Int,
        qosLabel: String
    ) {
        self.name = name
        self.tid = tid
        self.cpuPercent = cpuPercent
        self.qos = qos
        self.qosLabel = qosLabel
    }

    /// Our thread name (e.g. "Glimmer.enetControl") or, for an unnamed
    /// dispatch-queue worker, the queue label the OS exposes. Empty if neither is
    /// available - then `tid` disambiguates.
    @usableFromInline package var name: String
    /// Kernel thread id (`thread_identifier_info.thread_id`) - a stable per-thread
    /// label so an unnamed thread is still a distinct, attributable series.
    @usableFromInline package var tid: UInt64
    /// CPU usage, percent of ONE core (so a thread pegging a core reads ~100).
    @usableFromInline package var cpuPercent: Double
    /// QoS class ordinal (the raw `qos_class_t`): 33 user-interactive, 25
    /// user-initiated, 21 default, 17 utility, 9 background, 0 unspecified. The
    /// P-core-tier INTENT - a hot thread here should be 25/33 (P-tier).
    @usableFromInline package var qos: Int
    /// Compact QoS label for the dashboard ("userInteractive" / "utility" / ...).
    @usableFromInline package var qosLabel: String
}

/// One ~1Hz RESOURCE sample: the per-thread CPU/QoS lines, the process memory
/// footprint, and the AC-vs-battery power-source state. Plain value type built on
/// the exporter queue; rendered to both wire forms.
@usableFromInline package struct ResourceSnapshot: Sendable {

    @usableFromInline package init(
        threads: [ThreadResourceSample] = [],
        physFootprintBytes: UInt64? = nil,
        onBattery: Bool? = nil,
        batteryCharging: Bool? = nil
    ) {
        self.threads = threads
        self.physFootprintBytes = physFootprintBytes
        self.onBattery = onBattery
        self.batteryCharging = batteryCharging
    }

    /// The per-thread lines, sorted hottest-first so the top entries are the ones
    /// worth labelling. Capped (see `ResourceTelemetry.maxThreadsEmitted`) so a
    /// transient thread storm can't bloat a scrape - the cap keeps the busiest.
    @usableFromInline package var threads: [ThreadResourceSample] = []
    /// Process physical memory footprint, bytes - `task_vm_info.phys_footprint`
    /// (the Activity Monitor "Memory" number), or `resident_size` when the kernel
    /// leaves phys_footprint zero. nil on a probe miss.
    @usableFromInline package var physFootprintBytes: UInt64?
    /// True iff the Mac is on battery (the streaming machine unplugged - a power
    /// budget the scheduler may clamp, correlating with a perf dip). nil if the
    /// power source can't be read (e.g. a desktop with no battery → reads AC).
    @usableFromInline package var onBattery: Bool?
    /// True iff a battery exists and is charging (so "on AC, charging" vs "on AC,
    /// full" is distinguishable). nil when there is no battery.
    @usableFromInline package var batteryCharging: Bool?

    /// A stable, non-empty label for one thread's metric series: the thread name
    /// when we have one, else "unnamed". Unnamed workers are folded into a single
    /// aggregate upstream (`sampleThreads`), so per-tid labels never reach a series.
    @usableFromInline package func threadLabel(_ thread: ThreadResourceSample) -> String {
        thread.name.isEmpty ? "unnamed" : thread.name
    }
}
