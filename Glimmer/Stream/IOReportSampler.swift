//
//  IOReportSampler.swift
//
//  Opt-in P1 RESOURCE sampler #2 (system-level): SoC P-cluster vs E-cluster
//  ACTIVE RESIDENCY via Apple's IOReport "CPU Stats / CPU Complex Performance
//  States" channels, plus (bring-up #2) SoC PACKAGE POWER via "Energy Model"
//  and GPU ACTIVE RESIDENCY via "GPU Stats". The cluster half is the SYSTEM
//  side of the "are we using P vs E cores right?" question — the per-process
//  per-thread half lives in ResourceTelemetry. The power/GPU half closes the
//  one resource question neither could answer: is a heavy session GPU-bound or
//  thermal-budget-bound?
//
//  WHY IOReport (and the deliberate scope): IOReport is the same private-but-
//  stable C API `powermetrics`/asitop/macmon read. We dlopen it at RUNTIME
//  (/usr/lib/libIOReport.dylib resolves from the dyld shared cache) so there is
//  NO link-time framework dependency and NO change to the Xcode project — a
//  client-side-only addition.
//
//  SECOND BRING-UP (power + GPU), what attempt #1 missed: both groups needed a
//  different DECODE, not a different subscription. "Energy Model" channels are
//  SIMPLE-format integer accumulators — IOReportStateGetCount returns -1 for
//  them, so the state-residency parse read nothing; they decode via
//  IOReportSimpleGetIntegerValue plus the per-channel unit label ("CPU Energy"
//  is mJ while "GPU Energy" is nJ on the SAME SoC). And the GPU "GPUPH" state
//  channel matches neither the `E` nor `P` cluster-name prefix and idles in a
//  bucket named "OFF", so the CPU-cluster fold skipped it. With those decode
//  fixes the same minimal dlopen/subscription path reads both groups cleanly.
//  Package power = the "CPU Energy" + "GPU Energy" + ANE rails — the sum
//  powermetrics reports as "Combined Power (CPU + GPU + ANE)"; deliberately
//  NOT the DRAM/display/PCIe rails, so it tracks the compute work we cause.
//  Each group rides its OWN subscription, so a failure of either new read
//  degrades to nil without touching the proven cluster-residency path.
//
//  GATING + HOT-PATH SAFETY (load-bearing — see TelemetryExporter.swift):
//    * Constructed ONLY on the gate-on path (the exporter builds it in start()).
//      When telemetry is off (default) NOTHING here is constructed: no dlopen, no
//      subscription, no sample — zero overhead, exactly like WiFiTelemetry.
//    * Sampled ONLY on the exporter's serial workQueue at ~1Hz — NEVER a hot
//      path. There is no per-frame and no per-packet cost. Each IOReport delta
//      between two ~1s-apart samples is one cheap framework call.
//    * Any dlopen/symbol/subscription failure degrades to "no sample" (nil) so a
//      bring-up hiccup can never affect the stream — but NEVER silently: every
//      failing stage now leaves a one-time Diag NOTICE (see below). Without
//      these breadcrumbs the fields can ship DARK (zero rows, zero clues) even
//      when bring-up succeeds in a different environment — the many silent nil
//      paths mean a packaged app could be dead-on-arrival invisibly.
//
//  ENTITLE-OR-REMOVE DECISION (made on a packaged run's evidence — do not
//  pre-empt it in code):
//    * The prime suspect for production darkness is the App Sandbox
//      (Glimmer.entitlements enables it; a successful bring-up environment may
//      be unsandboxed). The stage-naming NOTICEs below settle sandbox-vs-API
//      in one instrumented packaged run.
//    * If sandbox-blocked: EITHER add the entitlement/exception the failing
//      stage needs (a deliberate security-surface decision, not a telemetry-pass
//      change), OR remove this sampler honestly: delete the file, its exporter
//      hook (TelemetryExporter+CaptureSections.fillResource), the NDJSON/prom
//      render keys, and gate the dashboard power/GPU panels off.
//    * If API-stage (a group/format change on a newer OS): fix the decode or
//      drop only the failing group — each group already degrades independently.
//    * What is NOT acceptable is the prior state: fields documented as shipped
//      yet absent from every row with no way to know why.
//
//  SECRET-FREE: residency fractions and package watts are pure SoC physics. No
//  host identity, keys, pairing material, or secrets.
//

import Foundation
import os

/// One ~1Hz SoC sample: P/E cluster active residency, package power, and GPU
/// active residency. Plain value type built on the exporter queue from
/// `IOReportSampler.sample()`; rendered to both wire forms. (The type name
/// predates the power/GPU fields — bring-up #1 carried only the cluster
/// residencies — and is kept so the capture/render call sites stay untouched.)
struct ClusterResidencySnapshot: Sendable {
    /// E-cluster (efficiency cores) active residency this window, 0…1. The cluster
    /// the LOW-QoS / background work should land on; high here while the stream is
    /// quiet is fine, high here while P is idle during active play is a hint our
    /// hot work got demoted.
    var eClusterActive: Double?
    /// P-cluster (performance cores) active residency this window, 0…1. The cluster
    /// our `.userInteractive` decode/pacer/receive threads SHOULD drive; this is the
    /// SoC-side confirmation the hot path is actually on the fast cores.
    var pClusterActive: Double?
    /// Number of distinct E-cluster channels folded into `eClusterActive` (so a
    /// reader knows the average spans e.g. ECPU+ECPM). 0 = none seen.
    var eClusterCount: Int = 0
    /// Number of distinct P-cluster channels folded into `pClusterActive`.
    var pClusterCount: Int = 0
    /// SoC package power this window, watts: the "CPU Energy" + "GPU Energy" +
    /// ANE rails of the "Energy Model" group over the window's wall time — the
    /// same sum powermetrics calls "Combined Power (CPU + GPU + ANE)". The
    /// thermal-budget signal: a 4K120 HDR session that creeps toward the SoC's
    /// sustained budget explains throttling before `thermal_state` moves. nil
    /// until the first clean delta or if the Energy Model read is unavailable.
    /// Export key `package_power_w` (T2 contract).
    var packagePowerW: Double?
    /// GPU active residency this window, 0…100 — the non-OFF share of the
    /// "GPU Stats / GPU Performance States" GPUPH window. PERCENT, not the 0…1
    /// of the cluster gauges above, matching the `gpu_residency_percent` export
    /// key (T2 contract). Answers "is heavy decode/present GPU-bound?". nil
    /// until the first clean delta or if the GPU Stats read is unavailable.
    var gpuResidencyPercent: Double?
}

/// IOReport-backed SoC sampler (cluster residency + package power + GPU
/// residency). Owned by the exporter, constructed only on the gate-on path.
/// `sample()` is called once per ~1Hz tick on the exporter's serial queue (one
/// caller, one thread).
///
/// `@unchecked Sendable`: the dlopen handle + IOReport subscriptions are touched
/// ONLY from the exporter's single serial queue, so access is serialized by
/// construction (same model as WiFiTelemetry's `CWWiFiClient`).
final class IOReportSampler: @unchecked Sendable {

    private let log = Logger(subsystem: "io.ugfugl.Glimmer", category: "Stream.Telemetry")

    // MARK: - IOReport C entry points (resolved once via dlopen / dlsym)
    //
    // Memory discipline: the IOReport `…Get…` accessors (channel name, state
    // name, unit label) follow the CF *Get* rule — they return +0 borrows owned
    // by the channel dictionary — so every read below uses
    // `takeUnretainedValue()`. Bring-up #2 caught the original
    // `takeRetainedValue()` over-release the hard way: it only survived on the
    // CPU path because names like "ECPU"/"IDLE" are tagged-pointer strings
    // (release is a no-op); the longer "Energy Model" names crashed. The
    // `…Copy…`/`…Create…` entry points stay +1 (`takeRetainedValue()`).

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
    /// subscriptions — bring-up #2, each OPTIONAL and independent: nil if its
    /// bring-up failed, in which case only its gauge stays nil.
    private let energySubscription: AnyObject?
    private let energyChannels: CFMutableDictionary?
    private let gpuSubscription: AnyObject?
    private let gpuChannels: CFMutableDictionary?

    /// Previous raw samples, so each tick produces a DELTA over the window
    /// (residency and accumulated energy are meaningful only as deltas between
    /// two instants). Confined to the exporter queue (the sole caller of
    /// `sample()`). nil until the first sample of each group.
    private var previousCpuSample: CFDictionary?
    private var previousEnergySample: CFDictionary?
    private var previousGpuSample: CFDictionary?
    /// Monotonic timestamp of the previous energy sample — energy-to-watts
    /// needs the window's actual wall time, not the nominal 1s cadence.
    private var previousEnergyTickNs: UInt64?

    /// First-sample outcome NOTICE state (the sensor-honesty contract: every
    /// sampler logs its first success OR failure once). Tick 1 is the designed
    /// delta baseline, so the verdict lands on tick 2; `lastClusterFailure`
    /// names the stage the required CPU-cluster read died at. Confined to the
    /// exporter queue like the sample state above.
    private var sampleTicks = 0
    private var firstSampleOutcomeLogged = false
    private var lastClusterFailure = "no sample attempted"

    /// One-time bring-up/runtime failure NOTICE, through Diag so it lands in
    /// the session log file (the os_log-only Logger here was never even
    /// invoked — structurally invisible postmortem).
    private static func noteBringUpFailure(_ stage: String) {
        Diag.notice("IOReport power/GPU telemetry unavailable — \(stage). "
            + "package_power_w / gpu_residency_percent / soc_* will be absent; "
            + "see the entitle-or-remove criteria in IOReportSampler.swift.",
            TelemetryExporter.logCategory)
    }

    // MARK: - Construction

    /// Build the sampler, or return nil if IOReport is unavailable — with a
    /// one-time Diag NOTICE naming the FAILING STAGE (dlopen / which dlsym /
    /// which subscription), so a packaged sandboxed run answers sandbox-vs-API
    /// from its session log instead of shipping silently-dark fields again.
    /// Called ONLY on the gate-on path (the exporter constructs it in start(),
    /// after the session log sink is up), so the dlopen + subscription cost is
    /// paid only when telemetry is opt-in ON — and the NOTICEs are bounded to
    /// one construction per session.
    init?() {
        // Resolves from the dyld shared cache — no on-disk file, no link-time dep.
        guard let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY) else {
            Self.noteBringUpFailure("dlopen(/usr/lib/libIOReport.dylib) returned nil"
                + " — sandbox denial is the prime suspect for a packaged build")
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

        // The CPU-cluster group is required — without it the sampler is nil,
        // exactly as in bring-up #1 (the subscribe above already named the stage).
        guard let cpu = subscribe("CPU Stats", "CPU Complex Performance States") else { return nil }
        // The power/GPU groups are best-effort extras; the energy one is only
        // worth holding if its simple-format decode pair resolved too.
        if simpleValue == nil || unitLabel == nil {
            Self.noteBringUpFailure("simple-format decode pair unresolved ("
                + missingSymbols.joined(separator: ", ") + ") — package_power_w disabled")
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

    /// Capture one SoC sample (a delta over the window since the last call).
    /// Returns nil on the FIRST call (no previous samples to delta against) and
    /// when every group read hiccupped; otherwise whichever of the cluster /
    /// power / GPU reads came through cleanly. On the exporter's serial queue —
    /// never the hot path. The first post-baseline outcome is logged ONCE
    /// (LIVE with the per-group inventory, or DARK naming the failing stage) so
    /// no session can ship these fields silently absent again.
    func sample() -> ClusterResidencySnapshot? {
        sampleTicks += 1
        var snapshot = sampleClusters() ?? ClusterResidencySnapshot()
        snapshot.packagePowerW = samplePackagePower()
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
            Diag.notice("IOReport sampler LIVE — clusters E:\(snapshot.eClusterCount)"
                + "/P:\(snapshot.pClusterCount), package power "
                + "\(snapshot.packagePowerW != nil ? "yes" : "NO"), GPU residency "
                + "\(snapshot.gpuResidencyPercent != nil ? "yes" : "NO").",
                TelemetryExporter.logCategory)
        }
        return snapshot
    }

    /// One cluster-residency delta. nil on the first call (baseline) and on any
    /// IOReport hiccup — each nil path names itself for the one-time DARK
    /// NOTICE in `sample()`.
    private func sampleClusters() -> ClusterResidencySnapshot? {
        guard let raw = createSamples(cpuSubscription, cpuChannels, nil)?.takeRetainedValue() else {
            lastClusterFailure = "IOReportCreateSamples(CPU Stats) returned nil"
            return nil
        }
        defer { previousCpuSample = raw }
        guard let previous = previousCpuSample,
              let delta = createSamplesDelta(previous, raw, nil)?.takeRetainedValue() else {
            // First sample: establish the baseline, emit nothing yet — but if
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

    /// One package-power delta, watts. Sums the top-level "CPU Energy" +
    /// "GPU Energy" + ANE rails — NOT every Energy Model channel: the group also
    /// carries the per-core / per-cluster / SRAM sub-rails those aggregates are
    /// built from (summing all would triple-count) plus DRAM/display/PCIe rails
    /// outside the conventional package sum. Units are read PER CHANNEL ("CPU
    /// Energy" is mJ, "GPU Energy" is nJ on the same SoC). nil on the first call
    /// (baseline), when the group's bring-up failed, and on any hiccup.
    private func samplePackagePower() -> Double? {
        guard let subscription = energySubscription, let channels = energyChannels,
              let simpleValue = simpleIntegerValue, let unitLabelOf = channelUnitLabel,
              let raw = createSamples(subscription, channels, nil)?.takeRetainedValue() else {
            return nil
        }
        let nowNs = DispatchTime.now().uptimeNanoseconds
        defer {
            previousEnergySample = raw
            previousEnergyTickNs = nowNs
        }
        guard let previous = previousEnergySample, let previousNs = previousEnergyTickNs,
              nowNs > previousNs,
              let delta = createSamplesDelta(previous, raw, nil)?.takeRetainedValue() else {
            return nil
        }
        let elapsedSeconds = Double(nowNs - previousNs) / 1_000_000_000.0
        var watts = 0.0
        var matchedAny = false
        for channel in reportChannels(in: delta) {
            guard let name = channelName(channel)?.takeUnretainedValue() as String? else { continue }
            // "ANE" is bare on this SoC, "ANE0/ANE1 …" on multi-die parts; the
            // SRAM exclusion keeps a hypothetical "ANE SRAM" sub-rail out.
            guard name == "CPU Energy" || name == "GPU Energy"
                    || (name.hasPrefix("ANE") && !name.contains("SRAM")) else { continue }
            let value = Double(simpleValue(channel, 0))
            guard value >= 0 else { continue }  // counter reset mid-window — skip.
            switch unitLabelOf(channel)?.takeUnretainedValue() as String? ?? "" {
            case "mJ": watts += value / 1e3 / elapsedSeconds; matchedAny = true
            case "uJ": watts += value / 1e6 / elapsedSeconds; matchedAny = true
            case "nJ": watts += value / 1e9 / elapsedSeconds; matchedAny = true
            default: break  // unknown unit: leave it out rather than guess.
            }
        }
        return matchedAny ? watts : nil
    }

    /// One GPU-residency delta, 0…100. The same state-bucket fold as the CPU
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
    /// so a multi-channel cluster (ECPU+ECPM, PCPU+PCPU1+…) reads as one number.
    private func parseClusters(delta: CFDictionary) -> ClusterResidencySnapshot? {
        var eSum = 0.0, eCount = 0
        var pSum = 0.0, pCount = 0
        for channel in reportChannels(in: delta) {
            guard let name = channelName(channel)?.takeUnretainedValue() as String?,
                  let active = activeResidency(of: channel) else { continue }
            // Channel names: ECPU/ECPM/ECPM_IDLE (efficiency), PCPU/PCPM/PCPU1/…
            // (performance). The `_IDLE` companion channels are a different view of
            // the same cluster — skip them so we don't double-count.
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

    /// Active residency (0…1) of one state-format channel: the sum of every
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
