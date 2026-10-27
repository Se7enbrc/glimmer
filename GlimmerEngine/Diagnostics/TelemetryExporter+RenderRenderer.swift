// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

#if os(macOS)
// AVFoundation's counters are renderer-scoped, not physical scanout or game FPS.

import Foundation

extension TelemetryRenderer {
    package static func ndjsonRendererPerformance(
        _ builder: inout NDJSONBuilder,
        _ sample: RendererPerformanceSnapshot?
    ) {
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

#endif
