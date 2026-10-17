// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  Types+StatsSnapshot.swift
//
//  StreamStatsSnapshot - the immutable per-window value type the stats overlay
//  renders (decode/network/latency/HDR fields and their formatting). Split out
//  of Types.swift to keep each unit focused; the row kinds + overlay config live
//  in Types+Stats.swift.
//

import GlimmerEngine
import Foundation

/// The HUD uses estimated PC capture FPS while telemetry retains pipeline rates.
/// Unavailable measurements stay nil so their rows remain neutral.
extension StreamStatsSnapshot {
    public func rows(
        enabled: Set<StatsRow.Kind>,
        targetFps: Double,
        thresholds: StatsThresholds = .default
    ) -> [StatsRow] {
        var out: [StatsRow] = []
        // Order matters - rows render top-to-bottom in this order. Within
        // a section the slot list is fixed; the user's `enabled` set just
        // gates which slots show up.
        let plan: [StatsRow.Kind] = [
            .hostFps, .networkFps, .decodeFps, .renderFps,
            .latency, .jitter, .networkDrops,
            .decoderDrops, .smoothness, .decodeTime, .bitrate, .hostProcessing,
            .macCpu, .macRam, .macBattery, .controllerBattery,
            .codec, .audio
        ]
        for kind in plan where enabled.contains(kind) {
            out.append(buildRow(kind: kind, targetFps: targetFps, thresholds: thresholds))
        }
        return out
    }

    /// Compose one row for the given kind. Centralises the
    /// label / symbol / formatting / health rule lookup so the row
    /// catalogue lives in one place and adding a new row is a one-case
    /// edit in the matching per-section builder plus an enum case in
    /// `StatsRow.Kind`. The dispatch is split by overlay section so each
    /// builder stays small and focused - the section a kind belongs to is
    /// fixed (it's encoded in the `section:` of every row it can produce).
    private func buildRow(kind: StatsRow.Kind, targetFps: Double, thresholds: StatsThresholds) -> StatsRow {
        switch kind {
        case .hostFps, .networkFps, .decodeFps, .renderFps:
            return frameRateRow(kind: kind, thresholds: thresholds)
        case .latency, .jitter, .networkDrops:
            return networkRow(kind: kind, thresholds: thresholds)
        case .decoderDrops, .bitrate, .decodeTime, .hostProcessing, .smoothness:
            return pipelineRow(kind: kind, targetFps: targetFps, thresholds: thresholds)
        case .macCpu, .macRam, .macBattery, .controllerBattery:
            return macRow(kind: kind)
        case .codec:
            return StatsRow(
                kind: .codec, label: "Codec", value: videoCodec ?? "-",
                symbolName: "film", health: .neutral, section: .config)
        case .audio:
            return StatsRow(
                kind: .audio, label: "Audio",
                value: audioConfigDescription ?? "\u{2014}",
                symbolName: "speaker.wave.2",
                health: .neutral, section: .config)
        }
    }

    /// Frame-rate section rows (host / network / decode / render FPS).
    private func frameRateRow(kind: StatsRow.Kind, thresholds: StatsThresholds) -> StatsRow {
        switch kind {
        case .networkFps:
            return StatsRow(
                kind: .networkFps, label: "Network",
                value: formatFps(receivedFps),
                symbolName: "network",
                health: fpsHealth(receivedFps, thresholds: thresholds),
                section: .frameRates)
        case .decodeFps:
            return StatsRow(
                kind: .decodeFps, label: "Decode",
                value: formatFps(decodedFps),
                symbolName: "cpu",
                health: fpsHealth(decodedFps, thresholds: thresholds),
                section: .frameRates)
        case .renderFps:
            let fps = hostFps ?? renderedFps
            return StatsRow(
                kind: .renderFps, label: "Render",
                value: formatFps(fps),
                symbolName: "display",
                health: fpsHealth(fps, thresholds: thresholds),
                section: .frameRates)
        default:
            // The PC row reports the capture estimate without judging the client.
            return StatsRow(
                kind: .hostFps, label: "PC",
                value: formatFps(hostFps),
                symbolName: "display",
                health: .neutral, section: .frameRates)
        }
    }

    /// Network section rows (latency / jitter / network drop rate).
    private func networkRow(kind: StatsRow.Kind, thresholds: StatsThresholds) -> StatsRow {
        switch kind {
        case .jitter:
            return StatsRow(
                kind: .jitter, label: "Jitter",
                value: formatMsDecimal(jitterMs ?? rttVarianceMs),
                symbolName: "waveform.path.ecg",
                health: jitterHealth(jitterMs ?? rttVarianceMs, thresholds: thresholds),
                section: .network)
        case .networkDrops:
            return StatsRow(
                kind: .networkDrops, label: "Drop rate",
                value: formatPercent(networkDroppedPercent),
                symbolName: "arrow.down.right",
                health: dropHealth(networkDroppedPercent, thresholds: thresholds),
                section: .network)
        default:
            // .latency
            return StatsRow(
                kind: .latency, label: "Latency",
                value: formatLatency(rtt: rttMs, jitter: jitterMs ?? rttVarianceMs),
                symbolName: "bolt.horizontal",
                health: latencyHealth(rttMs, thresholds: thresholds),
                section: .network)
        }
    }

    /// Pipeline section rows (drops / bitrate / decode time / host encode /
    /// smoothness).
    private func pipelineRow(kind: StatsRow.Kind, targetFps: Double, thresholds: StatsThresholds) -> StatsRow {
        switch kind {
        case .decoderDrops:
            // Real THREE-WAY drops-by-cause split. The headline is the decoder
            // drop %, but when ANY client-side drops have happened we append the
            // coherent decoder / backpressure / presentation-late counts (D/B/L)
            // so each cause shows a real number - previously two of the three
            // causes were hidden (backpressure folded into a "(+N RB)" suffix,
            // presentation-late buried in the Smoothness row), which made the
            // numbers look like they "never worked". Health stays keyed on the
            // decoder %, the most user-actionable signal.
            return StatsRow(
                kind: .decoderDrops, label: "Drops",
                value: formatDropsByCause(),
                symbolName: "exclamationmark.triangle",
                health: dropHealth(decoderDroppedPercent, thresholds: thresholds),
                section: .pipeline)
        case .decodeTime:
            return StatsRow(
                kind: .decodeTime, label: "Decode time",
                value: formatDecodeTime(),
                symbolName: "clock",
                health: Self.decodeTimeHealth(avgDecodeTimeMs, targetFps: targetFps),
                section: .pipeline)
        case .hostProcessing:
            // "PC encode", not "latency": the PC's capture and encode time
            // (Sunshine's frameHostProcessingLatency), which must never read as
            // this Mac's pipeline latency; the "Latency" row is the round trip.
            return StatsRow(
                kind: .hostProcessing, label: "PC encode",
                value: formatHostProcessingLatency(),
                symbolName: "cpu.fill",
                health: .neutral, section: .pipeline)
        case .smoothness:
            // Headline: present-cadence error + on-time fraction, with the
            // live pacing depth as a parenthetical and presentation-late
            // drops as a suffix when any have happened. Health keys off the
            // cadence error against the frame budget - judder is "presents
            // drifting a meaningful fraction of a frame off the grid".
            return StatsRow(
                kind: .smoothness, label: "Smoothness",
                value: formatSmoothness(),
                symbolName: "metronome",
                health: smoothnessHealth(targetFps: targetFps),
                section: .pipeline)
        default:
            // .bitrate
            return StatsRow(
                kind: .bitrate, label: "Bitrate",
                value: formatBitrate(measured: measuredBitrateMbps, negotiated: negotiatedBitrateMbps),
                symbolName: "gauge.with.dots.needle.bottom.50percent",
                health: .neutral, section: .pipeline)
        }
    }

    /// Mac-vitals section rows (CPU / RAM / Mac battery / controller battery).
    private func macRow(kind: StatsRow.Kind) -> StatsRow {
        switch kind {
        case .macRam:
            return StatsRow(
                kind: .macRam, label: "Mac RAM",
                value: formatPercent(macRamPercent),
                symbolName: "memorychip",
                health: .neutral, section: .mac)
        case .macBattery:
            return StatsRow(
                kind: .macBattery, label: "Mac battery",
                value: formatBattery(percent: macBatteryPercent, charging: macBatteryCharging),
                symbolName: batterySymbol(percent: macBatteryPercent, charging: macBatteryCharging),
                health: .neutral, section: .mac)
        case .controllerBattery:
            return StatsRow(
                kind: .controllerBattery, label: "Controller",
                value: formatBattery(percent: controllerBatteryPercent, charging: controllerBatteryCharging),
                symbolName: "gamecontroller",
                health: .neutral, section: .mac)
        default:
            // .macCpu
            return StatsRow(
                kind: .macCpu, label: "Mac CPU",
                value: formatPercent(macCpuPercent),
                symbolName: "cpu",
                health: .neutral, section: .mac)
        }
    }

    /// "85% · Charging" / "30% · On battery" / "-" for nil. Mirrors the
    /// macOS battery-indicator's two-line voice but tightened to a single
    /// row of right-aligned mono text. Symbol selection at the row level
    /// separately picks battery.0/25/50/75/100 + charge bolt.
    private func formatBattery(percent: Int?, charging: Bool?) -> String {
        guard let percent else { return "\u{2014}" }
        guard let charging else { return "\(percent) %" }
        return "\(percent) % · \(charging ? "Charging" : "On battery")"
    }

    /// Pick an SF Symbol from the `battery.*` family, or nil when there is
    /// no reading - an absent battery must render NO glyph, because every
    /// level glyph lies and the least-wrong one ("battery.0") reads as
    /// battery-empty: a standing false alarm on desktop Macs. Bolt overlay
    /// glyphs are surfaced separately for the charging-state communication;
    /// the regular fill levels (0/25/50/75/100) convey the percentage at a
    /// glance even before reading the value.
    private func batterySymbol(percent: Int?, charging: Bool?) -> String? {
        guard let percent else { return nil }
        if charging == true { return "battery.100.bolt" }
        switch percent {
        case ..<10: return "battery.0"
        case ..<35: return "battery.25"
        case ..<60: return "battery.50"
        case ..<85: return "battery.75"
        default: return "battery.100"
        }
    }

    // MARK: Health rules
    //
    // Rules consume `StatsThresholds` so the user can tune them in
    // Settings. Defaults are calibrated to "when does this actually start
    // to feel bad" - see `StatsThresholds.default`.

    private func fpsHealth(_ fps: Double?, thresholds: StatsThresholds) -> StatsRow.Health {
        guard let fps, thresholds.fpsWarningBelow > 0 || thresholds.fpsCriticalBelow > 0 else { return .neutral }
        if fps < Double(thresholds.fpsCriticalBelow) { return .critical }
        if fps < Double(thresholds.fpsWarningBelow) { return .warning }
        return .healthy
    }
    private func latencyHealth(_ rtt: Double?, thresholds: StatsThresholds) -> StatsRow.Health {
        guard let rtt else { return .neutral }
        if rtt > Double(thresholds.latencyCriticalAbove) { return .critical }
        if rtt > Double(thresholds.latencyWarningAbove) { return .warning }
        return .healthy
    }
    private func jitterHealth(_ j: Double?, thresholds: StatsThresholds) -> StatsRow.Health {
        guard let j else { return .neutral }
        if j > Double(thresholds.jitterCriticalAbove) { return .critical }
        if j > Double(thresholds.jitterWarningAbove) { return .warning }
        return .healthy
    }
    private func dropHealth(_ pct: Double?, thresholds: StatsThresholds) -> StatsRow.Health {
        guard let pct else { return .neutral }
        if pct > thresholds.dropsCriticalAbove { return .critical }
        if pct > thresholds.dropsWarningAbove { return .warning }
        return .healthy
    }
    /// Decode is pipelined, so time inside the frame budget is latency, not a fault.
    /// Only a decode longer than the whole frame budget falls behind the stream.
    static func decodeTimeHealth(_ decodeMs: Double?, targetFps: Double) -> StatsRow.Health {
        guard let decodeMs, targetFps > 0 else { return .neutral }
        return decodeMs > 1000.0 / targetFps ? .critical : .healthy
    }

    // MARK: Formatting helpers
    //
    // Reused per-tick at 1 Hz. They allocate Strings, but at this cadence the
    // allocation churn is negligible (dozens of strings every 1 s - orders of
    // magnitude under any reasonable jitter budget). We deliberately don't
    // cache: the values change every tick, so caching would buy nothing.

    private func formatFps(_ fps: Double?) -> String {
        guard let fps else { return "\u{2014}" }
        return String(format: "%.1f FPS", fps)
    }
    /// "0.4 ms · 99% (d2)" - average present-cadence error, on-time fraction,
    /// and live pacing depth, with a "+N late" suffix when the pacer has had
    /// to drop frames it couldn't present in time. Em-dash until the pacer has
    /// presented at least one frame this window.
    private func formatSmoothness() -> String {
        guard let err = avgPresentCadenceErrorMs,
              let onTime = onTimePresentPercent else {
            return "\u{2014}"
        }
        var text = String(format: "%.1f ms \u{00B7} %.0f%%", err, onTime)
        if let depth = pacingQueueDepth {
            text += String(format: " (d%d)", depth)
        }
        if let drops = presentationLateDrops, drops > 0 {
            text += " +\(drops) late"
        }
        return text
    }
    /// Smoothness health from the present-cadence error against the frame
    /// budget: warn when average error crosses a quarter-frame, critical at
    /// half a frame - at 60Hz that's >4.2ms warn / >8.3ms crit, tightening
    /// automatically at higher refresh. Neutral until the pacer reports.
    private func smoothnessHealth(targetFps: Double) -> StatsRow.Health {
        guard let err = avgPresentCadenceErrorMs, targetFps > 0 else { return .neutral }
        let frameBudget = 1000.0 / targetFps
        if err > frameBudget * 0.5 { return .critical }
        if err > frameBudget * 0.25 { return .warning }
        return .healthy
    }
    private func formatPercent(_ percent: Double?) -> String {
        guard let percent else { return "\u{2014}" }
        return String(format: "%.2f %%", percent)
    }
    private func formatMs(_ ms: Double?) -> String {
        guard let ms else { return "\u{2014}" }
        return String(format: "%.2f ms", ms)
    }
    /// "2.76 ms · 2.41 + 0.35 wait" once frames queue behind each other in VT.
    private func formatDecodeTime() -> String {
        guard let service = avgDecodeServiceMs, let wait = avgDecodeWaitMs, wait >= 0.05 else {
            return formatMs(avgDecodeTimeMs)
        }
        return formatMs(avgDecodeTimeMs) + String(format: " \u{00B7} %.2f + %.2f wait", service, wait)
    }
    /// Decimal-ms formatter for the network rows (jitter). Shows two decimals so
    /// a clean wired link's ~0.09ms jitter is legible instead of rounding to
    /// "0 ms" (the integer formatter's blur this replaces).
    private func formatMsDecimal(_ ms: Double?) -> String {
        guard let ms else { return "\u{2014}" }
        return String(format: "%.2f ms", ms)
    }
    /// "5.90 ms ±0.09" - RTT plus jitter as a single value cell, in DECIMAL ms.
    /// At ~6ms e2e a whole-ms RTT (the old integer formatter) read with ±halfms
    /// blur that hid the signal; two decimals make a 0.1ms change visible. The ±
    /// character is the standard math glyph (U+00B1), which SF Mono renders at a
    /// fixed advance so the numeric column stays aligned across ticks.
    private func formatLatency(rtt: Double?, jitter: Double?) -> String {
        guard let rtt else { return "\u{2014}" }
        if let jitter {
            return String(format: "%.2f ms \u{00B1}%.2f", rtt, jitter)
        }
        return String(format: "%.2f ms", rtt)
    }
    /// Three-way drops-by-cause: the decoder drop % headline plus a D/B/L count
    /// breakdown when any client-side drops exist -
    ///   D = decoder (VT rejected + pre-VT discards),
    ///   B = renderer backpressure (OS queue full),
    ///   L = presentation-late (pacer could not present in time).
    /// "0.00 %" alone when nothing has dropped (the clean-stream common case),
    /// "0.40 % · 12D/3B/0L" when drops have happened. Each cause is a real
    /// number - no cause is hidden in another row's suffix.
    private func formatDropsByCause() -> String {
        let pct = formatPercent(decoderDroppedPercent)
        let decoder = decoderDropCount ?? 0
        let backpressure = rendererBackpressureDrops ?? 0
        let late = presentationLateDrops ?? 0
        if decoder == 0 && backpressure == 0 && late == 0 {
            return pct
        }
        return pct + " \u{00B7} \(decoder)D/\(backpressure)B/\(late)L"
    }
    /// "2.0 / 8.0 / 5.0 ms" - min / max / avg host-side capture+encode
    /// latency. The triple is from Sunshine's `frameHostProcessingLatency`
    /// field and is window-relative (resets each snapshot).
    private func formatHostProcessingLatency() -> String {
        guard let lo = minHostProcessingLatencyMs,
              let hi = maxHostProcessingLatencyMs,
              let avg = avgHostProcessingLatencyMs else {
            return "\u{2014}"
        }
        return String(format: "%.1f / %.1f / %.1f ms", lo, hi, avg)
    }
    /// "45.2 / 50.0 Mbps" - measured-over-negotiated. We render both as
    /// monospaced numerics with a slash so the user can see the
    /// instantaneous bitrate against the ceiling they configured. When
    /// only one half is available we still render a slash with an em-dash
    /// in the missing slot to preserve column width.
    private func formatBitrate(measured: Double?, negotiated: Double?) -> String {
        switch (measured, negotiated) {
        case let (measured?, negotiated?):
            return String(format: "%.1f / %.0f Mbps", measured, negotiated)
        case let (measured?, nil):
            return String(format: "%.1f Mbps", measured)
        case let (nil, negotiated?):
            return String(format: "\u{2014} / %.0f Mbps", negotiated)
        default:
            return "\u{2014}"
        }
    }
}
