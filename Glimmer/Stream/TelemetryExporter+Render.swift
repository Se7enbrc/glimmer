//
//  TelemetryExporter+Render.swift
//
//  The PROMETHEUS core of the telemetry renderer (the NDJSON half + the
//  process-level CPU/thread sampler live in TelemetryExporter+RenderNDJSON.swift)
//  plus the shared histogram-quantile estimator both halves use: the
//  `prometheus(_:extras:)` entry point and the `PromBuilder` accumulator that
//  render a `TelemetrySnapshot` into the Prometheus text exposition form. The
//  metric-family sections live in TelemetryExporter+RenderVideo / +RenderNetwork /
//  +RenderAudio / +RenderSystem / +RenderP2.swift (pure moves - they append to
//  the same builder). Split out of TelemetryExporter.swift to keep each unit
//  focused; see that file for the exporter, gate, counters, and snapshot type.
//
//  PROMETHEUS NAMING: every metric is `glimmer_<area>_<name>`; gauges carry no
//  suffix, monotonic counters end `_total` (Prometheus convention). The shared
//  label set is `{session="<id>",host="<hostname>"}` so a scraper can split a
//  multi-session capture AND tell multiple scraped Macs apart by name (a remote
//  metrics sink's auto-attached `instance` label is just an IP:port). The
//  connect-relative offset is its own gauge so the INITIAL-CONNECTION phase is
//  visible on the timeline.
//

import Foundation
import SystemConfiguration

// MARK: - Renderer

enum TelemetryRenderer {

    /// This Mac's name - the `client` label on every emitted series (the box
    /// doing the watching). Paired with `host` (the Sunshine server we connect
    /// TO, per-session) so a multi-client rig splits both ways: which Mac, and
    /// which gaming PC. Reads the LocalHostName rather than the kernel hostname:
    /// a default macOS setup answers gethostname() with a generic "Mac", useless
    /// across clients - and LocalHostName is the same source a metrics shipper
    /// would bake into its labels, so the two always agree. Resolved ONCE on
    /// first render (a 1Hz utility-queue tick, never the hot path),
    /// `.local`-trimmed, pre-escaped for the exposition format so builders can
    /// splice it into a label set verbatim.
    /// Raw LocalHostName (JSON/display use - the NDJSON `client` field escapes
    /// it itself). `clientLabelValue` is the Prometheus-escaped form.
    static let clientNameRaw: String = {
        var name = (SCDynamicStoreCopyLocalHostName(nil) as String?)
            ?? ProcessInfo.processInfo.hostName
        if name.hasSuffix(".local") { name.removeLast(".local".count) }
        return name
    }()
    static let clientLabelValue: String = escapeLabel(clientNameRaw)

    /// Escape a label VALUE per the Prometheus text exposition format
    /// (backslash, double-quote, newline). Static so both `clientLabelValue`
    /// and `PromBuilder.init` (the per-session `host`) can pre-escape.
    static func escapeLabel(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    // MARK: Prometheus

    /// Render the full Prometheus text body. One `# HELP`/`# TYPE` pair per
    /// metric family followed by the sample line(s). Nil snapshot fields are
    /// omitted entirely (Prometheus has no "null" - an absent series is the
    /// correct representation of "no data this tick"). The sidecar Extras carry
    /// the counters sampled alongside the snapshot on the same capture tick.
    static func prometheus(_ snap: TelemetrySnapshot, extras: TelemetrySnapshot.Extras) -> String {
        var builder = PromBuilder(session: snap.sessionId, host: snap.serverName)
        promBuildInfo(&builder, snap)
        builder.emit("glimmer_session_uptime_seconds",
                     "Seconds since stream connect (INITIAL-CONNECTION phase visible).",
                     snap.sinceConnectSeconds)
        promFrames(&builder, snap)
        promNetwork(&builder, snap, extras)
        promPacing(&builder, snap, extras)
        promDrops(&builder, snap, extras)
        promRefresh(&builder, snap)
        promFrameSize(&builder, snap)
        promThermal(&builder, snap)
        promProcess(&builder, snap, extras)
        promResource(&builder, snap)
        promEventCounters(&builder, snap)
        promLatency(&builder, snap)
        promDecode(&builder, snap)
        promDisplay(&builder, snap, extras)
        promAudio(&builder, snap, extras)
        promWiFi(&builder, snap)
        // ENV-SIGNAL shadow state + the conditional-keepalive judge counters
        // (pings_sent / live cadence) - rendered right after the radio family
        // they gate on (TelemetryExporter+RenderNetwork.swift).
        promEnvSignal(&builder, extras)
        // P2 SESSION-LIFECYCLE: handshake breakdown, reconnect/disconnect, IDR
        // round-trip counts + last RTT, corruption. Rendered in a focused unit
        // (TelemetryExporter+RenderP2.swift) to keep this file under the length
        // budget; it appends to the SAME builder so the body stays one document.
        promSessionLifecycle(&builder, snap)
        return builder.out
    }

    /// Accumulator for one Prometheus body. Holds the shared
    /// `{session=...,client=...,host=...}` label set so each section just calls
    /// `emit` / `emitCounter`. `client` is this Mac; `host` is the Sunshine
    /// server this session connects to. Nil/non-finite gauges are skipped (an
    /// absent series is Prometheus's "no data"). Module-internal (not `private`)
    /// so the metric-family render sections (the TelemetryExporter+Render*
    /// siblings) can append to the same builder.
    struct PromBuilder {
        var out = ""
        let labels: String
        /// The shared pairs WITHOUT braces, for emitters that append extra labels.
        let sharedPairs: String
        /// - host: the Sunshine server name (per-session), already raw; escaped here.
        init(session: String, host: String) {
            sharedPairs = "session=\"\(session)\",client=\"\(TelemetryRenderer.clientLabelValue)\""
                + ",host=\"\(TelemetryRenderer.escapeLabel(host))\""
            labels = "{\(sharedPairs)}"
        }

        mutating func emit(_ name: String, _ help: String, _ value: Double?) {
            guard let value, value.isFinite else { return }
            out += "# HELP \(name) \(help)\n# TYPE \(name) gauge\n"
            out += "\(name)\(labels) \(format(value))\n"
        }
        mutating func emitCounter(_ name: String, _ help: String, _ value: UInt64) {
            out += "# HELP \(name) \(help)\n# TYPE \(name) counter\n"
            out += "\(name)\(labels) \(value)\n"
        }

        /// Emit one Prometheus histogram family: `_bucket{le=...}` for each finite
        /// bound plus the `+Inf` bucket, then `_sum` and `_count`. Buckets are
        /// cumulative ("le" semantics) - the tracker already maintains them that
        /// way. Skipped entirely when count == 0 (no data → absent series).
        mutating func emitHistogram(
            _ name: String, _ help: String, stage: LatencyHistogramSnapshot.Stage
        ) {
            guard stage.hasObservations else { return }
            out += "# HELP \(name) \(help)\n# TYPE \(name) histogram\n"
            // Insert the `le` label into the shared label set:
            // {session="...",client="...",host="...",le="..."}.
            // Each stage carries its OWN bounds (fine for sub-stages, coarse for
            // the composite glass-to-glass / input-to-photon stages).
            let prefix = String(labels.dropLast())  // drop trailing '}'
            for (index, bound) in stage.boundsMs.enumerated() where index < stage.buckets.count {
                out += "\(name)_bucket\(prefix),le=\"\(format(bound))\"} \(stage.buckets[index])\n"
            }
            out += "\(name)_bucket\(prefix),le=\"+Inf\"} \(stage.observationCount)\n"
            out += "\(name)_sum\(labels) \(format(stage.sumMs))\n"
            out += "\(name)_count\(labels) \(stage.observationCount)\n"
        }

        /// Emit a Prometheus INFO metric: a constant-1 gauge whose value carries
        /// in its LABELS (the standard `_info` pattern - e.g.
        /// `glimmer_build_info{commit="...",date="..."} 1`). Used for build
        /// attribution so a scrape ties every series to a build.
        mutating func emitInfo(_ name: String, _ help: String, labels infoLabels: [(String, String)]) {
            out += "# HELP \(name) \(help)\n# TYPE \(name) gauge\n"
            // Merge the shared session/client/host labels with the info labels.
            var pairs = sharedPairs
            for (key, value) in infoLabels { pairs += ",\(key)=\"\(escape(value))\"" }
            out += "\(name){\(pairs)} 1\n"
        }

        /// Emit a gauge that carries EXTRA labels beyond the shared session label
        /// (e.g. the Wi-Fi ssid/band). Skipped for nil/non-finite values.
        mutating func emitLabeled(
            _ name: String, _ help: String, _ value: Double?, labels extra: [(String, String)]
        ) {
            guard let value, value.isFinite else { return }
            out += "# HELP \(name) \(help)\n# TYPE \(name) gauge\n"
            var pairs = sharedPairs
            for (key, label) in extra { pairs += ",\(key)=\"\(escape(label))\"" }
            out += "\(name){\(pairs)} \(format(value))\n"
        }

        /// Escape a label VALUE per the Prometheus text exposition format.
        /// SSIDs / server names can contain quotes/backslashes; delegates to the
        /// shared escaper so client/host/extra labels all use one rule.
        private func escape(_ value: String) -> String {
            TelemetryRenderer.escapeLabel(value)
        }
    }

    /// Estimate a quantile (0...1) from cumulative histogram buckets via linear
    /// interpolation within the matching bucket - the same model Prometheus's
    /// `histogram_quantile` uses. Returns nil when the histogram is empty. Used
    /// ONLY for the per-second NDJSON snapshot's convenience p50/p95/p99 fields;
    /// the Prometheus side ships raw buckets so Grafana computes its own.
    static func histogramQuantile(
        _ quantile: Double, stage: LatencyHistogramSnapshot.Stage
    ) -> Double? {
        guard stage.hasObservations, !stage.buckets.isEmpty else { return nil }
        let rank = quantile * Double(stage.observationCount)
        // Find the first cumulative bucket whose count ≥ rank. Uses the stage's
        // OWN bounds so the composite (coarse) and sub-stage (fine) histograms
        // each interpolate against their matching edges.
        var lowerBound = 0.0
        var lowerCount = 0.0
        for (index, bound) in stage.boundsMs.enumerated() where index < stage.buckets.count {
            let cumulative = Double(stage.buckets[index])
            if cumulative >= rank {
                // Linear interpolation between (lowerBound, lowerCount) and
                // (bound, cumulative) for the fractional rank position.
                let span = cumulative - lowerCount
                let frac = span > 0 ? (rank - lowerCount) / span : 0
                return lowerBound + (bound - lowerBound) * frac
            }
            lowerBound = bound
            lowerCount = cumulative
        }
        // Past the last finite bound: clamp to the top bound (the +Inf bucket has
        // no upper edge to interpolate toward).
        return stage.boundsMs.last
    }

    /// Prometheus wants plain decimals, not Swift's exponent form for large/small
    /// values, and integers without a trailing ".0" where possible. Two decimals
    /// is plenty for a diagnostic gauge.
    private static func format(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(format: "%.3f", value)
    }
}
