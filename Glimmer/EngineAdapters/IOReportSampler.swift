// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// IOReport is resolved at runtime without a link-time dependency. Cluster residency tracks
// where CPU work runs; GPU residency is time awake at any clock. GPU and package watts
// measure energy cost, not utilization or the share of GPU capacity.

// Energy Model channels use SIMPLE integer accumulators, not state residency. Read units
// per channel: CPU Energy can be mJ while GPU Energy is nJ on the same SoC. Package power
// sums CPU + GPU + ANE compute rails, never DRAM/display/PCIe or overlapping sub-rails.

// GPUPH idles in OFF and matches neither the E nor P cluster prefix. Its separate state
// subscription and the Energy Model subscription degrade independently, preserving CPU
// residency if either optional group fails.

// Construct only on the telemetry gate-on path and sample at about 1 Hz on the exporter
// queue, never per frame or packet. When telemetry is off, there is no dlopen, subscription
// or sampling work. Values contain only SoC measurements, never identity or secrets.

// Every failing bring-up stage and the first sample outcome must leave a one-time Diag
// notice. If packaged builds cannot subscribe, remove the sampler and its exports; if an
// OS changes a group or format, fix its decode or drop that group, never ship silent absence.

// Keep the singleton and its subscriptions alive until process exit, resetting only delta
// baselines per session. Releasing IOReport's nested dictionaries crashed 2026.8.15 inside
// objc_release: real ownership does not obey the CF Create/Get rules suggested by API names.

import GlimmerEngine
import Foundation
import os

/// One opt-in SoC sample shared by both wire formats: CPU/GPU time awake and compute watts.
/// The original cluster snapshot name is retained for the existing capture/render call sites.
/// Process-lifetime sampler, borrowed by each opted-in session and reset with beginSession().
/// @unchecked Sendable: stateLock guards every mutable field across successive exporters' queues.
final class IOReportSampler: @unchecked Sendable {

    /// The one process-lifetime instance. Lazily built on first access, which
    /// is the exporter's gate-on construction, so the dlopen + subscription
    /// cost is still never paid when telemetry is off (the default). nil when
    /// IOReport is unavailable; that verdict is final for the process (the
    /// bring-up NOTICEs already named the failing stage once).
    static let shared: IOReportSampler? = IOReportSampler()

    /// Guards ALL mutable state below (previous samples, tick counter, log
    /// latches). Taken for the whole of `sample()` and `beginSession()` -
    /// ~1Hz, so contention is nil; correctness across session-queue changes
    /// is the point.
    private let stateLock = NSLock()

    private let log = Logger(subsystem: "io.ugfugl.Glimmer", category: "Stream.Telemetry")

    // MARK: - IOReport C entry points (resolved once via dlopen / dlsym)
    //
    // Memory discipline: the IOReport `...Get...` accessors (channel name, state
    // name, unit label) follow the CF *Get* rule - they return +0 borrows owned
    // by the channel dictionary - so every read below uses
    // `takeUnretainedValue()`. Bring-up #2 caught the original
    // `takeRetainedValue()` over-release the hard way: it only survived on the
    // CPU path because names like "ECPU"/"IDLE" are tagged-pointer strings
    // (release is a no-op); the longer "Energy Model" names crashed. The
    // `...Copy...`/`...Create...` entry points stay +1 (`takeRetainedValue()`).

    private typealias CopyChannelsInGroupT =
        @convention(c) (CFString, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    private typealias CreateSubscriptionT = @convention(c) (
        UnsafeRawPointer?, CFMutableDictionary,
        UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?) -> Unmanaged<AnyObject>?
    private typealias CreateSamplesT =
        @convention(c) (AnyObject, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias CreateSamplesDeltaT =
        @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias ChannelNameT = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias StateCountT = @convention(c) (CFDictionary) -> Int32
    private typealias StateNameForIndexT = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?
    private typealias StateResidencyT = @convention(c) (CFDictionary, Int32) -> Int64
    private typealias SimpleIntegerT = @convention(c) (CFDictionary, Int32) -> Int64
    private typealias UnitLabelT = @convention(c) (CFDictionary) -> Unmanaged<CFString>?

    private let copyChannelsInGroup: CopyChannelsInGroupT
    private let createSubscription: CreateSubscriptionT
    private let createSamples: CreateSamplesT
    private let createSamplesDelta: CreateSamplesDeltaT
    private let channelName: ChannelNameT
    private let stateCount: StateCountT
    private let stateNameForIndex: StateNameForIndexT
    private let stateResidency: StateResidencyT
    /// Simple-format decode pair, needed only by the "Energy Model" read.
    /// Resolved OPTIONALLY so a hypothetical OS that drops them costs us the
    /// power gauge, never the proven cluster-residency path.
    private let simpleIntegerValue: SimpleIntegerT?
    private let channelUnitLabel: UnitLabelT?

    /// The live CPU-cluster subscription + the channel dictionary it samples.
    /// Built once on the gate-on path; the sampler does not exist without it
    /// (bring-up #1 semantics, unchanged).
    private let cpuSubscription: AnyObject
    private let cpuChannels: CFMutableDictionary
    /// The "Energy Model" (package power) and "GPU Stats" (GPU residency)
    /// subscriptions - bring-up #2, each OPTIONAL and independent: nil if its
    /// bring-up failed, in which case only its gauge stays nil.
    private let energySubscription: AnyObject?
    private let energyChannels: CFMutableDictionary?
    private let gpuSubscription: AnyObject?
    private let gpuChannels: CFMutableDictionary?

    /// Previous raw samples, so each tick produces a DELTA over the window
    /// (residency and accumulated energy are meaningful only as deltas between
    /// two instants). Guarded by `stateLock`; reset by `beginSession()`. nil
    /// until the first sample of each group.
    private var previousCpuSample: CFDictionary?
    private var previousEnergySample: CFDictionary?
    private var previousGpuSample: CFDictionary?
    /// Monotonic timestamp of the previous energy sample - energy-to-watts
    /// needs the window's actual wall time, not the nominal 1s cadence.
    private var previousEnergyTickNs: UInt64?
    /// The last energy window saw matched rails but none advanced, so the
    /// baseline was held: the rail set is live, the reading just pending.
    private var energyWindowFlat = false

    /// First-sample outcome NOTICE state (the sensor-honesty contract: every
    /// sampler logs its first success OR failure once). Tick 1 is the designed
    /// delta baseline, so the verdict lands on tick 2; `lastClusterFailure`
    /// names the stage the required CPU-cluster read died at. Guarded by
    /// `stateLock` like the sample state above; reset per session.
    private var sampleTicks = 0
    private var firstSampleOutcomeLogged = false
    private var lastClusterFailure = "no sample attempted"

    /// One-shot guard for the unknown-unit warning: a matched rail we can't
    /// convert is dropped from the sum, so surface it once per session rather
    /// than silently undercount package power (the GPU-rail bug).
    private var loggedUnknownEnergyUnit = false

    /// One-time bring-up/runtime failure NOTICE, through Diag so it lands in
    /// the session log file (the os_log-only Logger here was never even
    /// invoked - structurally invisible postmortem).
    private static func noteBringUpFailure(_ stage: String) {
        Diag.notice("IOReport power/GPU telemetry unavailable - \(stage). "
            + "package_power_w / gpu_power_w / gpu_residency_percent / soc_* will be absent; "
            + "see the entitle-or-remove criteria in IOReportSampler.swift.",
            TelemetryExporter.logCategory)
    }

    // MARK: - Construction

    /// Build the sampler, or return nil if IOReport is unavailable - with a
    /// one-time Diag NOTICE naming the FAILING STAGE (dlopen / which dlsym /
    /// which subscription), so a packaged run names the failing stage from its
    /// session log instead of shipping silently-dark fields again.
    /// Reached ONLY through `shared`'s first gate-on access (after the session
    /// log sink is up), so the dlopen + subscription cost is paid only when
    /// telemetry is opt-in ON - and the NOTICEs are bounded to one
    /// construction per process.
    private init?() {
        // Resolves from the dyld shared cache - no on-disk file, no link-time dep.
        guard let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY) else {
            Self.noteBringUpFailure("dlopen(/usr/lib/libIOReport.dylib) returned nil")
            return nil
        }
        var missingSymbols: [String] = []
        func resolve<T>(_ name: String, as type: T.Type) -> T? {
            guard let sym = dlsym(handle, name) else {
                missingSymbols.append(name)
                return nil
            }
            return unsafeBitCast(sym, to: T.self)
        }
        let copyChannels = resolve("IOReportCopyChannelsInGroup", as: CopyChannelsInGroupT.self)
        let createSub = resolve("IOReportCreateSubscription", as: CreateSubscriptionT.self)
        let createSmp = resolve("IOReportCreateSamples", as: CreateSamplesT.self)
        let createDelta = resolve("IOReportCreateSamplesDelta", as: CreateSamplesDeltaT.self)
        let chName = resolve("IOReportChannelGetChannelName", as: ChannelNameT.self)
        let stCount = resolve("IOReportStateGetCount", as: StateCountT.self)
        let stName = resolve("IOReportStateGetNameForIndex", as: StateNameForIndexT.self)
        let stRes = resolve("IOReportStateGetResidency", as: StateResidencyT.self)
        guard let copyChannels, let createSub, let createSmp, let createDelta,
              let chName, let stCount, let stName, let stRes else {
            Self.noteBringUpFailure("dlsym failed for core symbol(s): "
                + missingSymbols.joined(separator: ", "))
            return nil
        }
        let simpleValue = resolve("IOReportSimpleGetIntegerValue", as: SimpleIntegerT.self)
        let unitLabel = resolve("IOReportChannelGetUnitLabel", as: UnitLabelT.self)

        /// Subscribe to EXACTLY one group/subgroup (the duplicated channel dict
        /// is what `IOReportCreateSamples` reads). nil on any failure, with the
        /// failing call named for the bring-up NOTICEs below.
        func subscribe(_ group: String, _ subgroup: String?) -> (AnyObject, CFMutableDictionary)? {
            guard let chans = copyChannels(
                group as CFString, subgroup.map { $0 as CFString }, 0, 0, 0
            )?.takeRetainedValue() else {
                Self.noteBringUpFailure("IOReportCopyChannelsInGroup(\"\(group)\") returned nil")
                return nil
            }
            var duplicated: Unmanaged<CFMutableDictionary>?
            guard let sub = createSub(nil, chans, &duplicated, 0, nil)?.takeRetainedValue(),
                  let dup = duplicated?.takeRetainedValue() else {
                Self.noteBringUpFailure("IOReportCreateSubscription(\"\(group)\") returned nil")
                return nil
            }
            return (sub, dup)
        }

        // The CPU-cluster group is required - without it the sampler is nil,
        // exactly as in bring-up #1 (the subscribe above already named the stage).
        guard let cpu = subscribe("CPU Stats", "CPU Complex Performance States") else { return nil }
        // The power/GPU groups are best-effort extras; the energy one is only
        // worth holding if its simple-format decode pair resolved too.
        if simpleValue == nil || unitLabel == nil {
            Self.noteBringUpFailure("simple-format decode pair unresolved ("
                + missingSymbols.joined(separator: ", ") + ") - package_power_w disabled")
        }
        let energy = (simpleValue != nil && unitLabel != nil) ? subscribe("Energy Model", nil) : nil
        let gpu = subscribe("GPU Stats", "GPU Performance States")

        self.copyChannelsInGroup = copyChannels
        self.createSubscription = createSub
        self.createSamples = createSmp
        self.createSamplesDelta = createDelta
        self.channelName = chName
        self.stateCount = stCount
        self.stateNameForIndex = stName
        self.stateResidency = stRes
        self.simpleIntegerValue = simpleValue
        self.channelUnitLabel = unitLabel
        self.cpuSubscription = cpu.0
        self.cpuChannels = cpu.1
        self.energySubscription = energy?.0
        self.energyChannels = energy?.1
        self.gpuSubscription = gpu?.0
        self.gpuChannels = gpu?.1
    }

    // MARK: - Sampling

    /// Reset the delta baselines and the per-session one-shot log latches.
    /// Called once per telemetry session (exporter construction), so a reused
    /// sampler never deltas against the PREVIOUS session's final sample and
    /// every session still gets its own LIVE/DARK verdict in the log.
    func beginSession() {
        stateLock.lock()
        defer { stateLock.unlock() }
        previousCpuSample = nil
        previousEnergySample = nil
        previousGpuSample = nil
        previousEnergyTickNs = nil
        energyWindowFlat = false
        sampleTicks = 0
        firstSampleOutcomeLogged = false
        lastClusterFailure = "no sample attempted"
        loggedUnknownEnergyUnit = false
    }

    /// Sample once per exporter tick, never on a hot path. The baseline tick and unavailable
    /// groups remain nil; the first post-baseline outcome logs LIVE with inventory or DARK with
    /// the failing stage so packaged sessions never ship silently absent fields.
    func sample() -> ClusterResidencySnapshot? {
        stateLock.lock()
        defer { stateLock.unlock() }
        sampleTicks += 1
        var snapshot = sampleClusters() ?? ClusterResidencySnapshot()
        let power = samplePackagePower()
        snapshot.packagePowerW = power?.package
        snapshot.gpuPowerW = power?.gpu
        snapshot.gpuResidencyPercent = sampleGpuResidency()
        let sawClusters = snapshot.eClusterCount > 0 || snapshot.pClusterCount > 0
        guard sawClusters || snapshot.packagePowerW != nil || snapshot.gpuResidencyPercent != nil else {
            if sampleTicks > 1 && !firstSampleOutcomeLogged {
                firstSampleOutcomeLogged = true
                Self.noteBringUpFailure("first delta produced no data (\(lastClusterFailure))")
            }
            return nil
        }
        if !firstSampleOutcomeLogged {
            firstSampleOutcomeLogged = true
            Diag.notice("IOReport sampler LIVE - clusters E:\(snapshot.eClusterCount)"
                + "/P:\(snapshot.pClusterCount), package power "
                + "\(snapshot.packagePowerW != nil || energyWindowFlat ? "yes" : "NO"), GPU residency "
                + "\(snapshot.gpuResidencyPercent != nil ? "yes" : "NO"), GPU power "
                + "\(snapshot.gpuPowerW != nil ? "yes" : "NO").",
                TelemetryExporter.logCategory)
        }
        return snapshot
    }

    /// One cluster-residency delta. nil on the first call (baseline) and on any
    /// IOReport hiccup - each nil path names itself for the one-time DARK
    /// NOTICE in `sample()`.
    private func sampleClusters() -> ClusterResidencySnapshot? {
        guard let raw = createSamples(cpuSubscription, cpuChannels, nil)?.takeRetainedValue() else {
            lastClusterFailure = "IOReportCreateSamples(CPU Stats) returned nil"
            return nil
        }
        defer { previousCpuSample = raw }
        guard let previous = previousCpuSample,
              let delta = createSamplesDelta(previous, raw, nil)?.takeRetainedValue() else {
            // First sample: establish the baseline, emit nothing yet - but if
            // a delta keeps failing, that IS the stage to report.
            lastClusterFailure = previousCpuSample == nil
                ? "first-sample baseline (designed)"
                : "IOReportCreateSamplesDelta(CPU Stats) returned nil"
            return nil
        }
        let parsed = parseClusters(delta: delta)
        if parsed == nil { lastClusterFailure = "CPU delta parsed but no E/P state channels matched" }
        return parsed
    }

    /// One Energy Model delta feeds both watt gauges. Per-channel units can differ on the same SoC.
    /// Keep a flat window's baseline until counters advance, so stale counters never claim zero cost.
    private func samplePackagePower() -> EnergyPower? {
        guard let subscription = energySubscription, let channels = energyChannels,
              let simpleValue = simpleIntegerValue, let unitLabelOf = channelUnitLabel,
              let raw = createSamples(subscription, channels, nil)?.takeRetainedValue() else {
            return nil
        }
        let nowNs = DispatchTime.now().uptimeNanoseconds
        var advanceBaseline = true
        defer {
            energyWindowFlat = !advanceBaseline
            if advanceBaseline {
                previousEnergySample = raw
                previousEnergyTickNs = nowNs
            }
        }
        guard let previous = previousEnergySample, let previousNs = previousEnergyTickNs,
              nowNs > previousNs,
              let delta = createSamplesDelta(previous, raw, nil)?.takeRetainedValue() else {
            return nil
        }
        let elapsedSeconds = Double(nowNs - previousNs) / 1_000_000_000.0
        var power = EnergyPower(elapsedSeconds: elapsedSeconds)
        for channel in reportChannels(in: delta) {
            guard let name = channelName(channel)?.takeUnretainedValue() as String?,
                  isPackageEnergyRail(name) else { continue }
            let value = Double(simpleValue(channel, 0))
            guard value >= 0 else { continue }  // counter reset mid-window - skip.
            let unit = unitLabelOf(channel)?.takeUnretainedValue() as String? ?? ""
            if !power.add(name: name, value: value, unit: unit), !loggedUnknownEnergyUnit {
                // A silent unknown-unit drop previously hid the GPU rail and understated package power.
                loggedUnknownEnergyUnit = true
                Diag.warn("IOReport Energy Model rail \"\(name)\" has unknown unit \"\(unit)\""
                    + " - excluded from package_power_w and gpu_power_w (sum may undercount).",
                    TelemetryExporter.logCategory)
            }
        }
        if power.package == 0 { advanceBaseline = false; return nil }
        return power
    }

    /// True only for the top-level CPU/GPU/ANE compute aggregates, matched by an
    /// exact name set (plus the bare/numbered ANE variant). A space-qualified
    /// sub-rail ("CPU Cluster 0 Energy") must not slip in and double-count.
    private func isPackageEnergyRail(_ name: String) -> Bool {
        if name == "CPU Energy" || name == "GPU Energy" { return true }
        // ANE is bare on single-die parts, "ANE0"/"ANE1" on multi-die ones; a
        // space marks a sub-rail (e.g. "ANE SRAM"), so reject anything with one.
        guard name.hasPrefix("ANE"), !name.contains(" ") else { return false }
        return name.dropFirst(3).allSatisfy(\.isNumber)
    }

    /// One GPU-residency delta, 0...100. The same state-bucket fold as the CPU
    /// clusters (GPUPH idles in "OFF", actives are its P-states), averaged
    /// across channels should a future SoC report more than the single GPUPH.
    /// nil on the first call (baseline), when the group's bring-up failed, and
    /// on any hiccup.
    private func sampleGpuResidency() -> Double? {
        guard let subscription = gpuSubscription, let channels = gpuChannels,
              let raw = createSamples(subscription, channels, nil)?.takeRetainedValue() else {
            return nil
        }
        defer { previousGpuSample = raw }
        guard let previous = previousGpuSample,
              let delta = createSamplesDelta(previous, raw, nil)?.takeRetainedValue() else {
            return nil
        }
        var sum = 0.0
        var folded = 0
        for channel in reportChannels(in: delta) {
            guard let active = activeResidency(of: channel) else { continue }
            sum += active
            folded += 1
        }
        guard folded > 0 else { return nil }
        return 100.0 * sum / Double(folded)
    }

    // MARK: - Parsing

    /// The delta's channel dictionaries (empty on any unexpected shape).
    private func reportChannels(in delta: CFDictionary) -> [CFDictionary] {
        let arrayPointer = CFDictionaryGetValue(
            delta, Unmanaged.passUnretained("IOReportChannels" as CFString).toOpaque())
        guard let arrayPointer else { return [] }
        let array = unsafeBitCast(arrayPointer, to: CFArray.self)
        return (0..<CFArrayGetCount(array)).map {
            unsafeBitCast(CFArrayGetValueAtIndex(array, $0), to: CFDictionary.self)
        }
    }

    /// Fold the delta's per-channel state buckets into E- vs P-cluster active
    /// residency. Each channel name starts with `E` (efficiency) or `P`
    /// (performance); within a channel, the `IDLE` (and `DOWN`) buckets are
    /// non-active and every other bucket is an active P-state. Active residency =
    /// active-ticks / total-ticks. We average across the channels of each cluster
    /// so a multi-channel cluster (ECPU+ECPM, PCPU+PCPU1+...) reads as one number.
    private func parseClusters(delta: CFDictionary) -> ClusterResidencySnapshot? {
        var eSum = 0.0, eCount = 0
        var pSum = 0.0, pCount = 0
        for channel in reportChannels(in: delta) {
            guard let name = channelName(channel)?.takeUnretainedValue() as String?,
                  let active = activeResidency(of: channel) else { continue }
            // Channel names: ECPU/ECPM/ECPM_IDLE (efficiency), PCPU/PCPM/PCPU1/...
            // (performance). The `_IDLE` companion channels are a different view of
            // the same cluster - skip them so we don't double-count.
            if name.hasSuffix("_IDLE") { continue }
            if name.hasPrefix("E") {
                eSum += active; eCount += 1
            } else if name.hasPrefix("P") {
                pSum += active; pCount += 1
            }
        }
        var snapshot = ClusterResidencySnapshot()
        if eCount > 0 { snapshot.eClusterActive = eSum / Double(eCount); snapshot.eClusterCount = eCount }
        if pCount > 0 { snapshot.pClusterActive = pSum / Double(pCount); snapshot.pClusterCount = pCount }
        return (eCount > 0 || pCount > 0) ? snapshot : nil
    }

    /// Active residency (0...1) of one state-format channel: the sum of every
    /// non-idle state bucket over the sum of ALL state buckets in this delta. The
    /// `IDLE` and `DOWN` buckets are the inactive states for the CPU clusters,
    /// `OFF` is the GPU's; everything else is an active voltage/frequency
    /// P-state. nil if the channel has no state buckets (simple-format channels
    /// report a count of -1 here).
    private func activeResidency(of channel: CFDictionary) -> Double? {
        let count = stateCount(channel)
        guard count > 0 else { return nil }
        var total = 0.0, active = 0.0
        for index in 0..<count {
            let residency = Double(stateResidency(channel, index))
            guard residency > 0 else { continue }
            total += residency
            let stateName = stateNameForIndex(channel, index)?.takeUnretainedValue() as String? ?? ""
            if stateName != "IDLE" && stateName != "DOWN" && stateName != "OFF" { active += residency }
        }
        guard total > 0 else { return nil }
        return active / total
    }
}

/// Missing rails stay absent, while a zero GPU delta alongside advancing CPU rails is real zero power.
struct EnergyPower {
    private let elapsedSeconds: Double
    private(set) var package: Double?
    private(set) var gpu: Double?

    init(elapsedSeconds: Double) {
        self.elapsedSeconds = elapsedSeconds
    }

    mutating func add(name: String, value: Double, unit: String) -> Bool {
        guard elapsedSeconds > 0, elapsedSeconds.isFinite, value >= 0, value.isFinite else { return false }
        let scale: Double
        switch unit {
        case "mJ": scale = 1e3
        case "uJ": scale = 1e6
        case "nJ": scale = 1e9
        default: return false
        }
        let watts = value / scale / elapsedSeconds
        package = (package ?? 0) + watts
        if name == "GPU Energy" { gpu = (gpu ?? 0) + watts }
        return true
    }
}
