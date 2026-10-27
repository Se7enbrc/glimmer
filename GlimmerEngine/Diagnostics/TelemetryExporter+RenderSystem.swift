// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

#if os(macOS)
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

    package static func promProcess(
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
        // Client-side input latency: queue→wire age of merged input on the batcher
        // (oldest unflushed entry → flush). The local half of the input path,
        // independent of host/present clock.
        builder.emitCounter("glimmer_input_timing_dropped_total", "Input timing capacity drops.",
                            snap.inputTimingDropped)
        if let stage = snap.inputCallbackLatency {
            builder.emitHistogram("glimmer_input_callback_queue_ms", "Local callback queue probe delay.", stage: stage)
        }
        if let inputLocal = snap.inputLocalLatency {
            builder.emitHistogram(
                "glimmer_latency_input_local_ms",
                "Client input queue→wire age histogram (batcher enqueue→flush), ms.",
                stage: inputLocal)
        }
        // Client input deliver→enqueue age histogram: the pre-hop main-thread leg
        // (GameController handler entry → batcher slot stamp) the local-latency
        // histogram above can't see (it starts at enqueue).
        if let inputDeliver = snap.inputDeliverLatency {
            builder.emitHistogram(
                "glimmer_latency_input_deliver_ms",
                "Client input deliver→enqueue age histogram (controller handler entry → "
                + "batcher slot stamp), ms.",
                stage: inputDeliver)
        }
        if let onBattery = snap.onBattery {
            builder.emit("glimmer_on_battery",
                         "1 while the providing power source is the internal battery.",
                         onBattery ? 1 : 0)
        }
        if let lowPower = snap.lowPowerMode {
            builder.emit("glimmer_low_power_mode",
                         "1 while macOS Low Power Mode is enabled.",
                         lowPower ? 1 : 0)
        }
        // Cruise forensics: batch-velocity + applied-gain distributions, split
        // MOVE vs DRAG (menu drag-pans vs held-button aim share the drag path,
        // so a drag-specific band tune needs this split). Units are counts/sec
        // and gain multipliers - not ms; the histogram bucketing is unit-agnostic.
        if let stage = snap.cruiseVelocityMove {
            builder.emitHistogram("glimmer_cruise_velocity_move",
                                  "Mouse batch velocity (counts/sec), free motion.", stage: stage)
        }
        if let stage = snap.cruiseVelocityDrag {
            builder.emitHistogram("glimmer_cruise_velocity_drag",
                                  "Mouse batch velocity (counts/sec), button-held drags.", stage: stage)
        }
        if let stage = snap.cruiseGainMove {
            builder.emitHistogram("glimmer_cruise_gain_move",
                                  "Applied Cruise gain per boosted batch, free motion.", stage: stage)
        }
        if let stage = snap.cruiseGainDrag {
            builder.emitHistogram("glimmer_cruise_gain_drag",
                                  "Applied Cruise gain per boosted batch, button-held drags.", stage: stage)
        }
        // Input flush ticks skipped by backpressure, split by which signal fired
        // (the input p99 tail attribution).
        builder.emitCounter("glimmer_input_flush_backpressure_skips_total",
                            "Input flush ticks skipped: local outbound send backlog over cap.",
                            snap.inputFlushSendBackloggedSkipTotal)
        builder.emitCounter("glimmer_input_flush_backpressure_reliable_skips_total",
                            "Input flush ticks skipped: host reliable-ACK backlog over cap.",
                            snap.inputFlushReliableBackloggedSkipTotal)
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
    package static func promResource(_ builder: inout PromBuilder, _ snap: TelemetrySnapshot) {
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
            promResourceMemory(&builder, resource)
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
            // Both formats share fillResource's single delta; a second read would corrupt baselines.
            // Unavailable groups and first-tick baselines stay absent, never zero.
            builder.emit("glimmer_package_power_w",
                         "SoC package power this window, watts - IOReport Energy Model "
                         + "CPU+GPU+ANE rails (powermetrics' Combined Power).",
                         cluster.packagePowerW)
            builder.emit("glimmer_gpu_residency_percent",
                         "GPU time awake at any clock this window, 0..100 percent; not capacity or power cost.",
                         cluster.gpuResidencyPercent)
            builder.emit("glimmer_gpu_power_w",
                         "GPU power this window, watts (IOReport Energy Model GPU Energy rail).",
                         cluster.gpuPowerW)
        }
    }

    /// Thermal + power state - catches throttling that correlates with a spike.
    package static func promThermal(_ builder: inout PromBuilder, _ snap: TelemetrySnapshot) {
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
    package static func promBuildInfo(_ builder: inout PromBuilder, _ snap: TelemetrySnapshot) {
        guard !snap.buildCommit.isEmpty else { return }
        builder.emitInfo(
            "glimmer_build_info",
            "Build attribution - commit SHA + build date (value is always 1).",
            labels: [("commit", snap.buildCommit), ("date", snap.buildDate)])
    }
    private static func promResourceMemory(_ builder: inout PromBuilder, _ resource: ResourceSnapshot) {
        builder.emit("glimmer_process_phys_footprint_bytes", "Kernel process physical footprint, bytes.",
                     resource.physFootprintBytes.map { Double($0) })
        builder.emit("glimmer_process_resident_size_bytes", "Process resident bytes; not physical footprint.",
                     resource.residentSizeBytes.map { Double($0) })
        builder.emit("glimmer_process_compressed_bytes", "Process compressed VM bytes.",
                     resource.compressedBytes.map { Double($0) })
        builder.emit("glimmer_process_internal_bytes", "Process internal VM bytes; categories overlap.",
                     resource.internalBytes.map { Double($0) })
        builder.emit("glimmer_process_reusable_bytes", "Process reusable VM bytes; categories overlap.",
                     resource.reusableBytes.map { Double($0) })
        builder.emit("glimmer_resource_sample_duration_ms", "Elapsed cost of the resource probe, milliseconds.",
                     resource.sampleDurationMs)
        builder.emit("glimmer_memory_probe_result", "Mach VM probe result; zero means success.",
                     resource.memoryProbeResult.map { Double($0) })
    }
}

#endif
