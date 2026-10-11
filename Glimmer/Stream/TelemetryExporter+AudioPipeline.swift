// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

extension TelemetryRenderer {
    static func promAudioPipeline(_ builder: inout PromBuilder, _ snapshot: AudioPipelineTelemetry.Snapshot?) {
        guard let snapshot else { return }
        for (name, stage) in audioPipelineStages(snapshot) {
            builder.emitHistogram("glimmer_\(name)_ms", "Audio pipeline duration in milliseconds.", stage: stage)
        }
        builder.emit("glimmer_audio_render_cushion_min_ms", "Minimum render-clock cushion this window.",
                          snapshot.window.minimumRenderCushionMs)
        builder.emit("glimmer_audio_near_misses_window", "Accounting near misses this capture window.",
                          Double(snapshot.window.nearMisses))
        builder.emit("glimmer_audio_decode_realtime", "Mach time constraint policy applied to audio worker.",
                          snapshot.window.realtime ? 1 : 0)
        for (name, count) in audioPipelineCounts(snapshot) {
            builder.emitCounter("glimmer_\(name)", "Audio pipeline cumulative events.", count)
        }
    }

    static func ndjsonAudioPipeline(_ builder: inout NDJSONBuilder, _ snapshot: AudioPipelineTelemetry.Snapshot?) {
        guard let snapshot else { return }
        let bounds = snapshot.receiveGap.boundsMs.map(jsonNumber).joined(separator: ",")
        builder.fields.append("\"audio_timing_bounds_ms\":[\(bounds)]")
        for (name, stage) in audioPipelineStages(snapshot) where stage.hasObservations {
            builder.add("\(name)_p50_ms", histogramQuantile(0.50, stage: stage))
            builder.add("\(name)_p95_ms", histogramQuantile(0.95, stage: stage))
            builder.add("\(name)_p99_ms", histogramQuantile(0.99, stage: stage))
            builder.addCount("\(name)_count", stage.observationCount)
            builder.add("\(name)_sum_ms", stage.sumMs)
            let buckets = stage.buckets.map(String.init).joined(separator: ",")
            builder.fields.append("\"\(name)_buckets\":[\(buckets)]")
        }
        builder.add("audio_render_cushion_min_ms", snapshot.window.minimumRenderCushionMs)
        builder.addCount("audio_near_misses_window", snapshot.window.nearMisses)
        builder.addBool("audio_decode_realtime", snapshot.window.realtime)
        for (name, count) in audioPipelineCounts(snapshot) { builder.addCount(name, count) }
    }

    private static func audioPipelineStages(
        _ snapshot: AudioPipelineTelemetry.Snapshot
    ) -> [(String, LatencyHistogramSnapshot.Stage)] {
        [("audio_receive_gap", snapshot.receiveGap), ("audio_decode_schedule", snapshot.decodeSchedule),
         ("audio_state_lock_wait", snapshot.stateLockWait), ("audio_queue_wait", snapshot.queueWait)]
    }

    private static func audioPipelineCounts(_ snapshot: AudioPipelineTelemetry.Snapshot) -> [(String, UInt64)] {
        [("audio_render_underrun_total", snapshot.window.renderUnderruns),
         ("audio_worker_overflow_total", snapshot.queueOverflow),
         ("audio_pcm_pool_exhausted_total", snapshot.poolExhausted),
         ("audio_reconfiguration_drop_total", snapshot.reconfigurationDrops)]
    }
}
