// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// AVFoundation's counters are renderer-scoped, not physical scanout or game FPS.

import Foundation

extension TelemetryRenderer {
    static func promRendererPerformance(_ builder: inout PromBuilder, _ sample: RendererPerformanceSnapshot?) {
        guard let sample else { return }
        builder.emitInfo("glimmer_renderer_metrics_status", "AVFoundation metrics sample state.",
                         labels: [("status", sample.status.rawValue)])
        builder.emitCounter("glimmer_renderer_metrics_resets_total", "Renderer replacements or counter resets observed.", sample.resets)
        builder.emit("glimmer_renderer_metrics_age_seconds", "Age of the last completed AVFoundation metrics sample.", sample.ageSeconds)
        builder.emit("glimmer_renderer_metrics_interval_seconds", "Time between the two samples used for deltas.", sample.intervalSeconds)
        if let values = sample.cumulative {
            builder.emitCounter("glimmer_renderer_frames_total",
                         "AVFoundation total frames if none were dropped; resets with renderer.", values.frames)
            builder.emitCounter("glimmer_renderer_dropped_frames_total",
                         "AVFoundation drops before decode or for missed display deadlines.", values.dropped)
            builder.emitCounter("glimmer_renderer_optimized_frames_total",
                         "AVFoundation frames using optimized compositing.", values.optimized)
            builder.emit("glimmer_renderer_accumulated_frame_delay_seconds",
                         "AVFoundation accumulated delay relative to sample PTS, not end-to-end latency.", values.delaySeconds)
        }
        if let delta = sample.delta {
            builder.emit("glimmer_renderer_frames_delta", "AVFoundation frame-count change between valid samples.", Double(delta.frames))
            builder.emit("glimmer_renderer_dropped_frames_delta",
                         "AVFoundation drop-count change between valid samples.", Double(delta.dropped))
            builder.emit("glimmer_renderer_optimized_frames_delta",
                         "Optimized-compositing frame-count change between valid samples.", Double(delta.optimized))
            builder.emit("glimmer_renderer_frame_delay_delta_seconds",
                         "Change in AVFoundation accumulated frame delay.", delta.delaySeconds)
        }
    }

    static func ndjsonRendererPerformance(_ builder: inout NDJSONBuilder, _ sample: RendererPerformanceSnapshot?) {
        guard let sample else { return }
        builder.addString("renderer_metrics_status", sample.status.rawValue)
        builder.addCount("renderer_metrics_resets_total", sample.resets)
        builder.add("renderer_metrics_age_s", sample.ageSeconds)
        builder.add("renderer_metrics_interval_s", sample.intervalSeconds)
        if let values = sample.cumulative {
            builder.addCount("renderer_frames_total", values.frames)
            builder.addCount("renderer_dropped_frames_total", values.dropped)
            builder.addCount("renderer_optimized_frames_total", values.optimized)
            builder.add("renderer_accumulated_frame_delay_s", values.delaySeconds)
        }
        if let delta = sample.delta {
            builder.addCount("renderer_frames_delta", delta.frames)
            builder.addCount("renderer_dropped_frames_delta", delta.dropped)
            builder.addCount("renderer_optimized_frames_delta", delta.optimized)
            builder.add("renderer_frame_delay_delta_s", delta.delaySeconds)
        }
    }
}
