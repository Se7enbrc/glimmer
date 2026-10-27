// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

#if os(macOS)
import Foundation

extension TelemetryRenderer {
    package static func ndjsonInputLatency(_ builder: inout NDJSONBuilder, _ rows: [InputLatency.Row]) {
        if rows.contains(where: { $0.histogram.hasObservations }) {
            let bounds = InputLatency.bounds.map(jsonNumber).joined(separator: ",")
            builder.addRaw(["\"input_latency_bounds_ms\":[" + bounds + "]"])
        }
        for row in rows where row.histogram.hasObservations {
            let name = "input_\(row.source.rawValue)_\(row.stage.rawValue)"
            for (label, quantile) in [("p50", 0.5), ("p95", 0.95), ("p99", 0.99)] {
                builder.add("\(name)_\(label)_ms", histogramQuantile(quantile, stage: row.histogram))
            }
            builder.add("\(name)_max_ms", row.maxMs)
            let buckets = row.histogram.buckets.map(String.init).joined(separator: ",")
            builder.addRaw(["\"\(name)_buckets\":[" + buckets + "]"])
            builder.addCount("\(name)_count", row.histogram.observationCount)
            builder.addCount("\(name)_over_10ms", row.over10)
            builder.addCount("\(name)_over_20ms", row.over20)
            builder.addCount("\(name)_over_50ms", row.over50)
        }
    }

    package static func promInputLatency(_ builder: inout PromBuilder, _ rows: [InputLatency.Row]) {
        for row in rows where row.histogram.hasObservations {
            let name = "glimmer_input_\(row.source.rawValue)_\(row.stage.rawValue)"
            builder.emitHistogram("\(name)_ms", "Local input stage latency in milliseconds.", stage: row.histogram)
            builder.emit("\(name)_max_ms", "Maximum local input stage latency in milliseconds.", row.maxMs)
            for (label, count) in [("10", row.over10), ("20", row.over20), ("50", row.over50)] {
                builder.emitCounter("\(name)_over_\(label)ms_total", "Input stage gaps above \(label) ms.", count)
            }
        }
    }
}

#endif
