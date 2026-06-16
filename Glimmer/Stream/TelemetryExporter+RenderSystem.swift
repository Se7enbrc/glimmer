//
//  TelemetryExporter+RenderSystem.swift
//
//  The PROMETHEUS render for the HOST/SYSTEM metric families: input + process
//  gauges, the P1 per-thread/QoS + SoC cluster-residency resource block, the
//  thermal/power state, and the build-info attribution gauge. Split from
//  TelemetryExporter+Render.swift - pure move, same file-split idiom as the
//  FramePacer split - to keep that file under the length budget. Each section
//  appends to the SAME `PromBuilder` (declared there) so the body stays one
//  document.
//

import Foundation

extension TelemetryRenderer {

    // MARK: - Host/system families

    static func promProcess(
        _ builder: inout PromBuilder, _ snap: TelemetrySnapshot, _ extras: TelemetrySnapshot.Extras
    ) {
        builder.emit("glimmer_input_events_per_second", "Input events submitted per second.",
                     snap.inputEventsPerSecond)
        builder.emit("glimmer_input_flush_per_second", "Input batcher flushes per second.",
                     snap.inputFlushPerSecond)
        builder.emitCounter("glimmer_input_idle_to_active_total",
                            "Idle→active input transitions (resume-after-idle marker).",
                            snap.inputIdleToActiveTotal)
        builder.emit("glimmer_input_since_last_ms",
                     "Milliseconds since the last input event.", snap.timeSinceLastInputMs)
        // Host rumble dispatched to pad actuators - same Extras sample as the
        // NDJSON rumble fields, riding the input family it correlates with.
        builder.emitCounter("glimmer_rumble_events_total",
                            "Host rumble events received at protocol dispatch (pre-guard).",
                            extras.rumbleEventTotal)
        builder.emit("glimmer_rumble_events_per_second",
                     "Host rumble events dispatched per second (~135/s during active rumble).",
                     extras.rumbleEventsPerSecond)
        builder.emitCounter("glimmer_rumble_dropped_invalid_total",
                            "Host rumble events dropped invalid (truncated / slot out of range).",
                            extras.rumbleDroppedInvalidTotal)
        builder.emit("glimmer_process_cpu_percent", "Process CPU usage, percent of one core.",
                     snap.processCpuPercent)
        builder.emit("glimmer_process_thread_count", "Live thread count.", snap.threadCount.map(Double.init))
    }

    /// P1 RESOURCE (the P-vs-E-core visibility signal). Three families:
    ///   * per-thread CPU% + a QoS-class gauge, each carrying `thread` + `qos`
    ///     labels (the hot-thread view + the P-core-tier INTENT, mapped to name);
    ///   * the SoC P-cluster vs E-cluster ACTIVE residency (the system-side
    ///     confirmation the hot work landed on the fast cores); and
    ///   * the process memory footprint + the on-battery / charging flags.
    static func promResource(_ builder: inout PromBuilder, _ snap: TelemetrySnapshot) {
        if let resource = snap.resource {
            for thread in resource.threads {
                // Both gauges carry the SAME thread+qos labels so a dashboard joins
                // "this thread's CPU%" with "its QoS tier" on one series.
                let labels = [("thread", resource.threadLabel(thread)),
                              ("qos", thread.qosLabel)]
                builder.emitLabeled("glimmer_thread_cpu_percent",
                                    "Per-thread CPU usage, percent of one core (hot-thread view).",
                                    thread.cpuPercent, labels: labels)
                builder.emitLabeled("glimmer_thread_qos",
                                    "Per-thread QoS class ordinal (33 userInteractive ... 9 background) "
                                    + "- the P-core-tier intent.",
                                    Double(thread.qos), labels: labels)
            }
            builder.emit("glimmer_process_phys_footprint_bytes",
                         "Process physical memory footprint, bytes (task_vm_info.phys_footprint).",
                         resource.physFootprintBytes.map(Double.init))
            if let onBattery = resource.onBattery {
                builder.emit("glimmer_power_on_battery",
                             "1 if the Mac is running on battery (unplugged), else 0.",
                             onBattery ? 1 : 0)
            }
            if let charging = resource.batteryCharging {
                builder.emit("glimmer_power_battery_charging",
                             "1 if the battery is charging, else 0.", charging ? 1 : 0)
            }
        }
        if let cluster = snap.clusterResidency {
            builder.emit("glimmer_soc_ecluster_active_residency",
                         "E-cluster (efficiency cores) active residency this window, 0..1 (IOReport).",
                         cluster.eClusterActive)
            builder.emit("glimmer_soc_pcluster_active_residency",
                         "P-cluster (performance cores) active residency this window, 0..1 (IOReport) "
                         + "- the SoC-side confirmation the hot path is on the fast cores.",
                         cluster.pClusterActive)
            // IOReport bring-up #2 (power/GPU) rides the SAME snapshot - the
            // sampler is delta-based, so it is read exactly once per tick (in
            // fillResource) and shared with NDJSON; a second read here would
            // corrupt its baselines. Each gauge degrades to nil independently
            // (group unavailable / first-tick baseline) and `emit` then omits
            // the family - the sampler's fail-quiet design, absent ≠ 0.
            builder.emit("glimmer_package_power_w",
                         "SoC package power this window, watts - IOReport Energy Model "
                         + "CPU+GPU+ANE rails (powermetrics' Combined Power).",
                         cluster.packagePowerW)
            builder.emit("glimmer_gpu_residency_percent",
                         "GPU active residency this window, 0..100 (IOReport GPU Stats: non-OFF "
                         + "share of the GPUPH states) - PERCENT, unlike the 0..1 cluster gauges.",
                         cluster.gpuResidencyPercent)
        }
    }

    /// Thermal + power state - catches throttling that correlates with a spike.
    static func promThermal(_ builder: inout PromBuilder, _ snap: TelemetrySnapshot) {
        builder.emit("glimmer_thermal_state",
                     "ProcessInfo thermal state ordinal (0 nominal ... 3 critical).",
                     snap.thermalState.map(Double.init))
        if let lowPower = snap.lowPowerModeEnabled {
            builder.emit("glimmer_low_power_mode", "1 if Low Power Mode is enabled, else 0.",
                         lowPower ? 1 : 0)
        }
    }

    /// Build attribution (signal 5a): `glimmer_build_info{commit,date} 1` so every
    /// scrape ties its series to a specific build (regression tracking).
    static func promBuildInfo(_ builder: inout PromBuilder, _ snap: TelemetrySnapshot) {
        guard !snap.buildCommit.isEmpty else { return }
        builder.emitInfo(
            "glimmer_build_info",
            "Build attribution - commit SHA + build date (value is always 1).",
            labels: [("commit", snap.buildCommit), ("date", snap.buildDate)])
    }
}
