//
//  ResourceTelemetry.swift
//
//  Opt-in P1 RESOURCE sampler (per-process): the PER-THREAD view that answers
//  "are we using P vs E cores right?" from OUR side - which threads are hot
//  (per-thread CPU%) and whether the hot ones carry a high QoS (the P-core-tier
//  INTENT), mapped to the thread NAME so a reader sees "decode 38% @
//  userInteractive" instead of an anonymous TID. Plus the process memory
//  footprint (task_vm_info.phys_footprint) and the AC-vs-battery power-source
//  state (IOPSCopyPowerSourcesInfo). The SYSTEM-side counterpart (P-cluster vs
//  E-cluster active residency via IOReport) lives in IOReportSampler.swift; the
//  two together bracket the question from intent (here) to outcome (there).
//
//  ALSO HERE: a one-shot QoS AUDIT (`QoSAudit`) the exporter logs once at start -
//  it confirms the hot-path threads are on `.userInteractive` and FLAGS any hot
//  thread that is NOT high-QoS, so a future regression that demotes the decode or
//  pacer queue surfaces immediately instead of as mysterious judder. The audit is
//  derived from the SAME per-thread sample, so it costs nothing extra.
//
//  GATING + HOT-PATH SAFETY (load-bearing - see TelemetryExporter.swift):
//    * Every sampler here is a pure static read called ONLY on the exporter's
//      ~1Hz serial workQueue (and the one-shot audit at start) - NEVER a hot
//      path. There is no per-frame and no per-packet cost.
//    * When telemetry is off (default) the exporter never exists, so none of this
//      is ever called: zero overhead. The per-thread enumeration mirrors the
//      already-shipped `ProcessMetrics.sample()` (one task_threads + per-thread
//      thread_info) - it is cheap and bounded by the thread count (tens), run at
//      1Hz, not on any decode/pacer/receive thread.
//    * Any Mach/IOKit failure degrades to "no sample" (nil / empty), so a probe
//      hiccup can never affect the stream.
//
//  SECRET-FREE: thread names are our OWN labels, CPU%/QoS/footprint are numbers,
//  the power-source state is a local hardware fact. No host identity or secrets.
//

import Foundation
import Darwin
import IOKit.ps

// MARK: - Per-thread sample

/// One thread's resource line for the per-thread CPU / QoS view. `cpuPercent` is
/// percent of one core (matching `ProcessMetrics`); `qos` is the thread's QoS
/// class INTENT (the P-vs-E tier the scheduler honours); `name` is our own thread
/// label so the hot line is self-describing.
struct ThreadResourceSample: Sendable {
    /// Our thread name (e.g. "Glimmer.enetControl") or, for an unnamed
    /// dispatch-queue worker, the queue label the OS exposes. Empty if neither is
    /// available - then `tid` disambiguates.
    var name: String
    /// Kernel thread id (`thread_identifier_info.thread_id`) - a stable per-thread
    /// label so an unnamed thread is still a distinct, attributable series.
    var tid: UInt64
    /// CPU usage, percent of ONE core (so a thread pegging a core reads ~100).
    var cpuPercent: Double
    /// QoS class ordinal (the raw `qos_class_t`): 33 user-interactive, 25
    /// user-initiated, 21 default, 17 utility, 9 background, 0 unspecified. The
    /// P-core-tier INTENT - a hot thread here should be 25/33 (P-tier).
    var qos: Int
    /// Compact QoS label for the dashboard ("userInteractive" / "utility" / ...).
    var qosLabel: String
}

// MARK: - Resource snapshot

/// One ~1Hz RESOURCE sample: the per-thread CPU/QoS lines, the process memory
/// footprint, and the AC-vs-battery power-source state. Plain value type built on
/// the exporter queue; rendered to both wire forms.
struct ResourceSnapshot: Sendable {
    /// The per-thread lines, sorted hottest-first so the top entries are the ones
    /// worth labelling. Capped (see `ResourceTelemetry.maxThreadsEmitted`) so a
    /// transient thread storm can't bloat a scrape - the cap keeps the busiest.
    var threads: [ThreadResourceSample] = []
    /// Process physical memory footprint, bytes - `task_vm_info.phys_footprint`
    /// (the Activity Monitor "Memory" number), or `resident_size` when the kernel
    /// leaves phys_footprint zero. nil on a probe miss.
    var physFootprintBytes: UInt64?
    /// True iff the Mac is on battery (the streaming machine unplugged - a power
    /// budget the scheduler may clamp, correlating with a perf dip). nil if the
    /// power source can't be read (e.g. a desktop with no battery → reads AC).
    var onBattery: Bool?
    /// True iff a battery exists and is charging (so "on AC, charging" vs "on AC,
    /// full" is distinguishable). nil when there is no battery.
    var batteryCharging: Bool?

    /// A stable, non-empty label for one thread's metric series: the thread name
    /// when we have one, else `tid-<id>` so an unnamed worker is still a distinct,
    /// attributable series rather than collapsing into one empty-name bucket.
    func threadLabel(_ thread: ThreadResourceSample) -> String {
        thread.name.isEmpty ? "tid-\(thread.tid)" : thread.name
    }
}

// MARK: - Sampler

/// Static per-process resource samplers. No state - each call is a fresh read on
/// the exporter's serial queue (never a hot path).
enum ResourceTelemetry {

    /// Cap on per-thread lines emitted per tick (busiest kept). Tens of threads is
    /// the norm; the cap bounds a pathological storm so a scrape stays bounded.
    static let maxThreadsEmitted = 24

    /// Threads below this CPU% are dropped from the emitted set UNLESS they are one
    /// of our NAMED hot-path threads (we always want decode/pacer/receive visible
    /// even when momentarily idle, so a QoS regression on an idle tick still shows).
    static let cpuFloorPercent = 0.5

    /// Map a `qos_class_t` ordinal to a compact dashboard label.
    static func qosLabel(_ qos: Int) -> String {
        switch UInt32(qos) {
        case QOS_CLASS_USER_INTERACTIVE.rawValue: return "userInteractive"
        case QOS_CLASS_USER_INITIATED.rawValue: return "userInitiated"
        case QOS_CLASS_DEFAULT.rawValue: return "default"
        case QOS_CLASS_UTILITY.rawValue: return "utility"
        case QOS_CLASS_BACKGROUND.rawValue: return "background"
        default: return "unspecified"
        }
    }

    /// True iff this QoS class is the P-core / "hot-path-appropriate" tier
    /// (user-interactive or user-initiated). The QoS audit flags a hot thread that
    /// is NOT one of these.
    static func isHighQoS(_ qos: Int) -> Bool {
        UInt32(qos) == QOS_CLASS_USER_INTERACTIVE.rawValue
            || UInt32(qos) == QOS_CLASS_USER_INITIATED.rawValue
    }

    /// Capture the per-thread CPU/QoS/name lines + the memory footprint + the
    /// power-source state. One `task_threads` + per-thread `thread_info` (mirrors
    /// `ProcessMetrics.sample()`), one `task_info(TASK_VM_INFO)`, one
    /// `IOPSCopyPowerSourcesInfo`. All on the exporter's 1Hz queue - never a hot
    /// path.
    static func sample() -> ResourceSnapshot {
        var snapshot = ResourceSnapshot()
        snapshot.threads = sampleThreads()
        snapshot.physFootprintBytes = sampleFootprint()
        let power = samplePowerSource()
        snapshot.onBattery = power.onBattery
        snapshot.batteryCharging = power.charging
        return snapshot
    }

    /// Enumerate live threads → (name, tid, cpu%, qos). Keeps the busiest +
    /// always-keeps our named hot-path threads, then sorts hottest-first and caps.
    private static func sampleThreads() -> [ThreadResourceSample] {
        var threadList: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &threadList, &threadCount) == KERN_SUCCESS,
              let threads = threadList else { return [] }
        defer {
            for index in 0..<Int(threadCount) {
                mach_port_deallocate(mach_task_self_, threads[index])
            }
            vm_deallocate(mach_task_self_,
                          vm_address_t(UInt(bitPattern: threads)),
                          vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride))
        }
        var samples: [ThreadResourceSample] = []
        samples.reserveCapacity(Int(threadCount))
        for index in 0..<Int(threadCount) {
            guard let sample = sampleOne(thread: threads[index]) else { continue }
            // Keep a thread if it's drawing measurable CPU, OR it's one of our
            // named hot-path threads (so its QoS stays auditable even when idle).
            let named = sample.name.hasPrefix("io.ugfugl.Glimmer") || sample.name.hasPrefix("Glimmer.")
            if sample.cpuPercent >= cpuFloorPercent || named { samples.append(sample) }
        }
        samples.sort { $0.cpuPercent > $1.cpuPercent }
        if samples.count > maxThreadsEmitted { samples.removeLast(samples.count - maxThreadsEmitted) }
        return samples
    }

    /// Read one thread's CPU% + name + tid + QoS. nil if the thread is the idle
    /// thread or its basic-info read failed.
    private static func sampleOne(thread: thread_t) -> ThreadResourceSample? {
        let basicInfoCount = mach_msg_type_number_t(
            MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        var basic = thread_basic_info()
        var count = basicInfoCount
        let result = withUnsafeMutablePointer(to: &basic) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS, (basic.flags & TH_FLAGS_IDLE) == 0 else { return nil }
        let cpuPercent = Double(basic.cpu_usage) / Double(TH_USAGE_SCALE) * 100.0

        // Kernel thread id (stable per-thread label).
        var tid: UInt64 = 0
        let idCount = mach_msg_type_number_t(
            MemoryLayout<thread_identifier_info_data_t>.size / MemoryLayout<natural_t>.size)
        var ident = thread_identifier_info()
        var identCount = idCount
        let identResult = withUnsafeMutablePointer(to: &ident) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(identCount)) {
                thread_info(thread, thread_flavor_t(THREAD_IDENTIFIER_INFO), $0, &identCount)
            }
        }
        if identResult == KERN_SUCCESS { tid = ident.thread_id }

        // Name + QoS via the pthread that backs this Mach thread.
        var name = ""
        var qos = 0
        if let pthread = pthread_from_mach_thread_np(thread) {
            var nameBuffer = [CChar](repeating: 0, count: 64)
            if pthread_getname_np(pthread, &nameBuffer, nameBuffer.count) == 0 {
                // TRIM AT THE FIRST NUL before conversion. `String(validating:)`
                // consumes the WHOLE 64-byte buffer (embedded NULs are valid
                // UTF-8), so every name carried its NUL padding: an unnamed
                // thread rendered as 64 \u0000 escapes - ~1.5KB of pure noise
                // per NDJSON row across 24 threads - and the never-empty result
                // meant the `tid-<id>` fallback could not fire. Truncating at
                // the terminator restores both the real names (P/E-core
                // visibility, the field's whole point) and the fallback.
                let trimmed = Array(nameBuffer.prefix(while: { $0 != 0 }))
                name = String(validating: trimmed, as: UTF8.self) ?? ""
            }
            var qosClass = qos_class_t(rawValue: 0)
            var relativePriority: Int32 = 0
            if pthread_get_qos_class_np(pthread, &qosClass, &relativePriority) == 0 {
                qos = Int(qosClass.rawValue)
            }
        }
        return ThreadResourceSample(
            name: name, tid: tid, cpuPercent: cpuPercent, qos: qos, qosLabel: qosLabel(qos))
    }

    /// Integer_t index of `phys_footprint` within `task_vm_info` - the kernel
    /// must return a count past this field or it stays zero-initialized (the
    /// "reads 0 every session" tell). `resident_size` sits far earlier and is
    /// always filled, so it's the honest fallback.
    private static let physFootprintIndex =
        (MemoryLayout<task_vm_info_data_t>.offset(of: \.phys_footprint) ?? .max)
        / MemoryLayout<integer_t>.size

    /// Process physical memory footprint (bytes) via `task_vm_info`. Falls back
    /// to `resident_size` when the kernel returns a short count or a zero
    /// `phys_footprint`, so the metric carries a real number instead of a dead 0.
    /// nil only on an outright task_info failure.
    private static func sampleFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let covered = Int(count) > physFootprintIndex
        if covered, info.phys_footprint > 0 { return UInt64(info.phys_footprint) }
        if info.resident_size > 0 { return UInt64(info.resident_size) }
        return nil
    }

    /// AC-vs-battery + charging via IOKit power sources. `onBattery` is nil when no
    /// battery exists (a desktop reads AC and we leave the flag absent rather than
    /// asserting "not on battery" for a machine that can't be).
    private static func samplePowerSource() -> (onBattery: Bool?, charging: Bool?) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return (nil, nil) }
        // The system-wide providing-source type: "AC Power" or "Battery Power".
        // CF *Get* rule: IOPSGetProvidingPowerSourceType returns +0 (the IOKit.ps
        // header says the caller must NOT release it), so this must be
        // takeUnretainedValue(). The previous takeRetainedValue() over-released
        // once per 1Hz capture tick and survived only because the documented
        // return values are immortal compile-time CFSTR constants - the exact
        // masking that already burned IOReport bring-up (IOReportSampler.swift:
        // the tagged-pointer names survived, the heap-allocated ones crashed).
        let providing = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?
        guard let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef],
              !sources.isEmpty else {
            // No internal battery enumerated (desktop): report on-battery only if
            // the providing type somehow says battery; otherwise leave it absent.
            if providing == kIOPSBatteryPowerValue { return (true, nil) }
            return (nil, nil)
        }
        // A laptop: derive the on-battery flag from the internal battery's state.
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            let state = description[kIOPSPowerSourceStateKey] as? String
            let charging = description[kIOPSIsChargingKey] as? Bool
            let onBattery = state == kIOPSBatteryPowerValue
            return (onBattery, charging)
        }
        return (nil, nil)
    }
}

// MARK: - QoS audit (one-shot, at exporter start)

/// One-shot QoS audit derived from a per-thread sample. Confirms our hot-path
/// queues are on `.userInteractive` (the P-core tier) and FLAGS any hot thread
/// that is not high-QoS, so a regression that demotes the decode/pacer/receive
/// queue surfaces in the log the moment telemetry comes up - instead of as
/// unexplained judder. Logged once by the exporter on start; never on a hot path.
enum QoSAudit {

    /// The hot-path thread NAMES we EXPECT to be high-QoS. These are the actual
    /// `pthread_getname_np` names the receive/control threads set on themselves
    /// (`Glimmer.videoRecv`/`.audioRecv` via pthread_setname_np, `.enetControl`
    /// via Thread.name) - NOT DispatchQueue labels, which the OS does not surface
    /// as pthread names (a queue worker reads back empty → `tid-N`). The earlier
    /// `io.ugfugl.Glimmer.*` queue-label list matched zero real threads and the
    /// audit was dead. The `.userInitiated`/`.utility` ping/control queues are
    /// deliberately omitted - those tiers are CORRECT there and must NOT flag.
    static let expectedHotPathLabels = [
        "Glimmer.videoRecv",
        "Glimmer.audioRecv",
        "Glimmer.enetControl"]

    /// Run the audit over a sample and log the result once. Reports the high-QoS
    /// confirmation for the hot-path threads it can see, and warns for any thread
    /// drawing real CPU that is on a low QoS tier (the demotion tell). Purely
    /// observational - it changes NO scheduling, only reports.
    static func runAndLog(_ snapshot: ResourceSnapshot, category: String) {
        var confirmed: [String] = []
        var demotions: [String] = []
        var matchedHotPath = false
        for thread in snapshot.threads {
            let isHotPath = expectedHotPathLabels.contains { thread.name.hasPrefix($0) }
            if isHotPath {
                matchedHotPath = true
                if ResourceTelemetry.isHighQoS(thread.qos) {
                    confirmed.append("\(thread.name)=\(thread.qosLabel)")
                } else {
                    demotions.append("\(thread.name)=\(thread.qosLabel) "
                        + String(format: "(%.0f%% CPU)", thread.cpuPercent))
                }
            } else if thread.cpuPercent >= 5.0 && !ResourceTelemetry.isHighQoS(thread.qos) {
                // A non-hot-path thread burning ≥5% on a low tier is worth a glance
                // (it might be ours under a different name) - flag it, don't fail.
                demotions.append("\(thread.name.isEmpty ? "tid \(thread.tid)" : thread.name)"
                    + "=\(thread.qosLabel) " + String(format: "(%.0f%% CPU)", thread.cpuPercent))
            }
        }
        if !confirmed.isEmpty {
            Diag.notice("QoS audit OK - hot-path threads on P-core tier: "
                + confirmed.joined(separator: ", ") + ". (Network.swift .utility queue is "
                + "control-plane, correctly NOT hot-path.)", category)
        }
        if !demotions.isEmpty {
            Diag.warn("QoS audit FLAG - thread(s) on a low QoS tier while drawing CPU: "
                + demotions.joined(separator: ", ") + " - a hot path may have been demoted "
                + "off the P-core tier.", category)
        }
        if !matchedHotPath {
            // None of expectedHotPathLabels matched a live thread. At start this
            // can be benign pre-roll, but it's ALSO the exact symptom of the
            // dead-audit bug (names drift out of sync with the threads). Warn so a
            // future rename is visible instead of silently re-deadening the audit.
            Diag.warn("QoS audit - no hot-path threads (\(expectedHotPathLabels.joined(separator: ", ")))"
                + " found in this sample; either pre-roll or the expected thread names have "
                + "drifted out of sync with the receive/control threads.", category)
        }
    }
}
