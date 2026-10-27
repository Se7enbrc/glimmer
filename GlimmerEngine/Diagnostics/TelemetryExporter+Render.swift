// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

#if os(macOS)
//
//  TelemetryExporter+Render.swift
//
//  The Prometheus core of the telemetry renderer: `prometheus(_:extras:)`, the
//  `PromBuilder` every metric section appends to, and the per-install pseudonyms that
//  stand in for the PC and Mac names. Metrics are `glimmer_<area>_<name>`; counters end `_total`.
//

import CryptoKit
import Foundation

// MARK: - Renderer

package enum TelemetryRenderer {

    /// This Mac's `client` label: its LocalHostName as a pseudonym, so files people
    /// attach to issues tell Macs apart without naming them. Resolved once.

    /// A PC or Mac name as 8 hex digits, keyed by a random per-install salt: stable
    /// across sessions, but no one without the salt can match it to a name.
    package static func pseudonym(_ name: String, salt: SymmetricKey = installSalt) -> String {
        HMAC<SHA256>.authenticationCode(for: Data(name.utf8), using: salt)
            .prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    package static let installSalt: SymmetricKey = {
        let key = "telemetryNameSalt"
        if let stored = PersistentStorage.defaults.data(forKey: key), stored.count == 32 {
            return SymmetricKey(data: stored)
        }
        let salt = SymmetricKey(size: .bits256)
        PersistentStorage.defaults.set(salt.withUnsafeBytes { Data($0) }, forKey: key)
        return salt
    }()

    /// Escape a label VALUE per the Prometheus text exposition format
    /// (backslash, double-quote, newline).
    package static func escapeLabel(_ value: String) -> String {
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
    package static func prometheus(_ snap: TelemetrySnapshot, extras: TelemetrySnapshot.Extras) -> String {
        var builder = PromBuilder(session: snap.sessionId, host: snap.serverName, client: snap.clientLabel)
        promBuildInfo(&builder, snap)
        builder.emit("glimmer_session_uptime_seconds",
                     "Seconds since stream connect (INITIAL-CONNECTION phase visible).",
                     snap.sinceConnectSeconds)
        promFrames(&builder, snap)
        promRendererPerformance(&builder, snap.rendererPerformance)
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
        // ENV-SIGNAL state + the conditional-keepalive judge counters
        // (pings_sent / live cadence) - rendered right after the radio family
        // they gate on (TelemetryExporter+RenderNetwork.swift).
        promEnvSignal(&builder, extras)
        // P2 SESSION-LIFECYCLE: handshake breakdown, reconnect/disconnect, IDR
        // round-trip counts + last RTT, corruption. Rendered in a focused unit
        // (TelemetryExporter+RenderP2.swift) to keep this file under the length
        // budget; it appends to the SAME builder so the body stays one document.
        promSessionLifecycle(&builder, snap)
        promInputLatency(&builder, snap.inputLatency)
        return builder.out
    }

    /// Accumulator for one Prometheus body. Holds the shared
    /// `{session=...,client=...,host=...}` label set so each section just calls
    /// `emit` / `emitCounter`. `client` is this Mac; `host` is the Sunshine
    /// server this session connects to. Nil/non-finite gauges are skipped (an
    /// absent series is Prometheus's "no data"). Module-internal (not `private`)
    /// so the metric-family render sections (the TelemetryExporter+Render*
    /// siblings) can append to the same builder.
    package struct PromBuilder {
        package var out = ""
        package let labels: String
        /// The shared pairs WITHOUT braces, for emitters that append extra labels.
        package let sharedPairs: String
        /// - host: the PC's pseudonym for this session; escaped here.
        package init(session: String, host: String, client: String = "") {
            sharedPairs = "session=\"\(session)\",client=\"\(client)\""
                + ",host=\"\(TelemetryRenderer.escapeLabel(host))\""
            labels = "{\(sharedPairs)}"
        }

        package mutating func emit(_ name: String, _ help: String, _ value: Double?) {
            guard let value, value.isFinite else { return }
            out += "# HELP \(name) \(help)\n# TYPE \(name) gauge\n"
            out += "\(name)\(labels) \(TelemetryRenderer.jsonNumber(value))\n"
        }
        package mutating func emitCounter(_ name: String, _ help: String, _ value: UInt64) {
            out += "# HELP \(name) \(help)\n# TYPE \(name) counter\n"
            out += "\(name)\(labels) \(value)\n"
        }

        /// Emit one counter FAMILY: a `# HELP/# TYPE` header followed by one series
        /// per (extra-label, value) row, each merging the shared session labels with
        /// its own extra label. For per-reason/per-bucket counter families.
        package mutating func emitCounterFamily(
            _ name: String, _ help: String, key: String, rows: [(label: String, value: UInt64)]
        ) {
            guard !rows.isEmpty else { return }
            out += "# HELP \(name) \(help)\n# TYPE \(name) counter\n"
            for row in rows {
                out += "\(name){\(sharedPairs),\(key)=\"\(escape(row.label))\"} \(row.value)\n"
            }
        }

        /// Emit one Prometheus histogram family: `_bucket{le=...}` for each finite
        /// bound plus the `+Inf` bucket, then `_sum` and `_count`. Buckets are
        /// cumulative ("le" semantics) - the tracker already maintains them that
        /// way. Skipped entirely when count == 0 (no data → absent series).
        package mutating func emitHistogram(
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
                out +=
                    "\(name)_bucket\(prefix),le=\"\(TelemetryRenderer.jsonNumber(bound))\"} \(stage.buckets[index])\n"
            }
            out += "\(name)_bucket\(prefix),le=\"+Inf\"} \(stage.observationCount)\n"
            out += "\(name)_sum\(labels) \(TelemetryRenderer.jsonNumber(stage.sumMs))\n"
            out += "\(name)_count\(labels) \(stage.observationCount)\n"
        }

        /// Emit a Prometheus INFO metric: a constant-1 gauge whose value carries
        /// in its LABELS (the standard `_info` pattern - e.g.
        /// `glimmer_build_info{commit="...",date="..."} 1`). Used for build
        /// attribution so a scrape ties every series to a build.
        package mutating func emitInfo(_ name: String, _ help: String, labels infoLabels: [(String, String)]) {
            out += "# HELP \(name) \(help)\n# TYPE \(name) gauge\n"
            // Merge the shared session/client/host labels with the info labels.
            var pairs = sharedPairs
            for (key, value) in infoLabels { pairs += ",\(key)=\"\(escape(value))\"" }
            out += "\(name){\(pairs)} 1\n"
        }

        /// Emit a gauge that carries EXTRA labels beyond the shared session label
        /// (e.g. the Wi-Fi ssid/band). Skipped for nil/non-finite values.
        package mutating func emitLabeled(
            _ name: String, _ help: String, _ value: Double?, labels extra: [(String, String)]
        ) {
            guard let value, value.isFinite else { return }
            out += "# HELP \(name) \(help)\n# TYPE \(name) gauge\n"
            var pairs = sharedPairs
            for (key, label) in extra { pairs += ",\(key)=\"\(escape(label))\"" }
            out += "\(name){\(pairs)} \(TelemetryRenderer.jsonNumber(value))\n"
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
    package static func histogramQuantile(
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
}

#endif
