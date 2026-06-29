//
//  Types+StatsSnapshot.swift
//
//  StreamStatsSnapshot - the immutable per-window value type the stats overlay
//  renders (decode/network/latency/HDR fields and their formatting). Split out
//  of Types.swift to keep each unit focused; the row kinds + overlay config live
//  in Types+Stats.swift.
//

import Foundation

/// Per-tick snapshot of stream performance counters, surfaced to the in-stream
/// stats overlay (toggled with the user's stats hotkey). The values are read
/// off the `VideoDecoder` accumulators at a fixed cadence (1 Hz) and rendered
/// into a multi-row CALayer compositor over the AVSampleBufferDisplayLayer.
///
/// Field semantics mirror moonlight-qt's VIDEO_STATS rows in
/// `ffmpeg.cpp::stringifyVideoStats` - same units, same source data - but
/// the surface is row-based (`rows(enabled:targetFps:)`) so the overlay can
/// pick which rows to render and assign per-row health colors. Anything we
/// can't compute locally and the host doesn't report (e.g. the host's true
/// encode FPS, network-dropped-frame percentage) is `nil` and renders as an
/// em-dash row with `neutral` health.
public struct StreamStatsSnapshot: Sendable {
    /// Host-side encoder frame rate. We don't have a reliable source for
    /// this - the host doesn't report its true encode FPS over the protocol -
    /// so we report the configured stream FPS as the best available proxy.
    /// Matches what moonlight-qt's "Estimated host PC frame rate" row shows
    /// when only the configured rate is known.
    public var hostFps: Double?
    /// Incoming frame rate from the network - the rate at which decode units
    /// land in our `submitDecodeUnit` callback (after the native receiver
    /// depacketizes and reassembles each frame).
    public var receivedFps: Double?
    /// Decoding frame rate - successful VT decode-output callbacks per
    /// second.
    public var decodedFps: Double?
    /// Rendering frame rate - `AVSampleBufferVideoRenderer.enqueue` calls
    /// per second. Once enqueued, the OS owns v-sync pacing.
    public var renderedFps: Double?

    /// Frames dropped by the network connection, as a percentage of total
    /// frames. We don't surface this number yet, so we leave it nil and
    /// render as "-".
    public var networkDroppedPercent: Double?
    /// Frames dropped by the decoder (VT reported `kVTDecodeInfo_FrameDropped`
    /// in its output callback), as a percentage of frames the decoder saw.
    public var decoderDroppedPercent: Double?

    /// Average network RTT in milliseconds, from `LiGetEstimatedRttInfo`.
    /// `Double` (not `UInt32`) so the overlay shows decimal ms - at ~6ms e2e a
    /// whole-ms RTT reads with ±halfms blur that hides the signal. The ENet
    /// estimate is whole-ms on the wire today, but plumbing it as Double lets a
    /// finer RTT source surface without a type change and keeps the formatter
    /// uniform with jitter.
    public var rttMs: Double?
    /// Variance of the RTT estimate, in milliseconds, from
    /// `LiGetEstimatedRttInfo`. `Double` for the same decimal-resolution reason.
    public var rttVarianceMs: Double?

    /// Network jitter in milliseconds - variation in packet inter-arrival
    /// time. The truthful definition (RFC 3550) is the smoothed mean
    /// deviation of the difference between consecutive RTP arrival
    /// timestamps. The native RTP receiver computes this directly on its
    /// receive thread (it owns the socket, so it sees every arrival), which
    /// is the real signal - not the RTT-variance proxy a black-box transport
    /// would force.
    ///
    /// Populated by `StreamSession`'s 1Hz overlay timer from the FINE RFC-3550
    /// smoothed receive jitter (`TelemetryCounters.shared.recvJitterMs`, already
    /// Double). On a clean wired link jitter is ~0.09ms, which an integer field
    /// would round to "0 ms" (no signal), so `Double` keeps real sub-ms
    /// resolution.
    public var jitterMs: Double?

    /// EMA of decoder wall-clock time per frame, in milliseconds (time
    /// between `VTDecompressionSessionDecodeFrame` submission and the
    /// matching decompression-output callback fire).
    public var avgDecodeTimeMs: Double?

    /// Host-side capture + encode latency, in milliseconds, as reported by
    /// Sunshine on each DECODE_UNIT (`frameHostProcessingLatency` in
    /// Limelight.h - 1/10 ms units on the wire, converted to ms here). This
    /// is measured on the *host* and tells us how long the host spent
    /// producing the frame; do not confuse it with `avgDecodeTimeMs`, which
    /// is our own client-side VT decode wall-clock. Min / max / average are
    /// computed across the sampling window - same shape as moonlight-qt's
    /// "Host processing latency min/max/average" row. All three values are
    /// nil until we've seen at least one frame with a non-zero latency in
    /// the current window (GFE never populates the field; Sunshine populates
    /// it for most frames but emits zero for repeated frames).
    public var minHostProcessingLatencyMs: Double?
    public var maxHostProcessingLatencyMs: Double?
    public var avgHostProcessingLatencyMs: Double?

    /// Configured / negotiated stream bitrate in Mbps. This is the rate
    /// the host was asked to encode at - the "headline" bitrate the user
    /// configured. Useful as a baseline next to the measured number.
    public var negotiatedBitrateMbps: Double?
    /// Measured bytes-into-VideoToolbox over the last sampling window,
    /// converted to Mbps. The actual rate the host is currently
    /// transmitting, which can dip well below the configured bitrate when
    /// the scene is mostly static.
    public var measuredBitrateMbps: Double?

    /// Total renderer-backpressure drops since the session started.
    /// AVSampleBufferVideoRenderer dropped these frames because its
    /// internal queue was full (`isReadyForMoreMediaData == false`).
    /// Tracked separately from decoder drops because the failure mode is
    /// different: this is "OS-side queue got full, we're behind on
    /// display" not "VT rejected the bitstream". Surfaced in the overlay
    /// only when non-zero - a healthy stream stays at 0 and we don't want
    /// to add a row of clutter for the common case.
    public var rendererBackpressureDrops: UInt64?

    /// Absolute session-cumulative decoder-side drop count (VT rejected, plus
    /// pre-VT discards now credited via `recordDecoderDiscard`). The
    /// `decoderDroppedPercent` row shows the percentage; this raw count feeds the
    /// dedicated three-way drops-by-cause line so each cause shows a real number
    /// instead of two of them hiding in suffixes.
    public var decoderDropCount: UInt64?

    // ---- Frame-pacer smoothness -------------------------------------------
    //
    // Populated from the StatsCollector pacer counters. These describe how
    // evenly frames are reaching the screen - the buttery-smooth-pass signal
    // that the FPS rows alone can't show (you can hit 60 rendered fps and
    // still judder if the presents are unevenly spaced).

    /// Live pacing-queue depth: frames buffered in the pacer waiting for a
    /// vsync, sampled at the display's tick rate. 1-2 is the healthy target;
    /// a sustained 3 means we're riding the cap (latency creeping up).
    public var pacingQueueDepth: Int?
    /// Peak pacing-queue depth over the sampling window - surfaces a transient
    /// build the live gauge would miss.
    public var pacingQueueDepthMax: Int?
    /// Average magnitude of present-vs-PTS cadence error this window, in ms.
    /// The headline smoothness number: how far each present landed from the
    /// ideal grid. Near zero = buttery; growth = judder.
    public var avgPresentCadenceErrorMs: Double?
    /// Worst present-vs-PTS cadence error this window, in ms - the spike a
    /// user perceives as a hitch.
    public var maxPresentCadenceErrorMs: Double?
    /// Percentage of presents this window that landed on-cadence (within the
    /// collector's perceptual tolerance). 100% = perfectly paced.
    public var onTimePresentPercent: Double?
    /// Total frames the pacer dropped because it could not present them in
    /// time (jitter-buffer overflow / sustained-lag trim). The NEW third drop
    /// cause, distinct from decoder and renderer-backpressure drops. Session-
    /// cumulative; surfaced in the Smoothness row's suffix when non-zero.
    public var presentationLateDrops: UInt64?
    /// Perceived present gaps (renderer showed nothing fresh) - the badge's
    /// felt-stutter signal. Session-cumulative; catch-up discards don't count.
    public var presentationGaps: UInt64?

    /// Live audio-config label ("Stereo", "5.1 surround", "7.1 surround").
    /// Read from the session-active AudioConfig - post-codec-agent the
    /// default is `AudioConfig.bestForCurrentOutput()` rather than
    /// hardcoded `.stereo`, and the overlay needs to reflect that. nil
    /// pre-session-start.
    public var audioConfigDescription: String?

    /// Mac-side host vitals sampled per-tick from `MacSystemStats.shared`.
    /// All nil-able so a probe failure (or a desktop with no battery)
    /// surfaces as em-dash instead of "0%".
    public var macBatteryPercent: Int?
    public var macBatteryCharging: Bool?
    public var macCpuPercent: Double?
    public var macRamPercent: Double?

    /// Connected game-controller battery (first attached pad reporting one).
    /// Nil when no controller is attached or the pad doesn't expose a battery
    /// (wired pads, or pads GameController can't read) - renders as em-dash.
    public var controllerBatteryPercent: Int?
    public var controllerBatteryCharging: Bool?

    // ---- Frame size + type (telemetry only; no overlay row) -----------------
    //
    // Window-relative per-frame byte size + IDR fraction, surfaced ONLY by the
    // opt-in telemetry exporter (not rendered in the overlay). These positively
    // EXCLUDE - or catch - the big-frame / recurring-IDR hypothesis behind the
    // idle-resume spike: a resume that fires a large IDR shows here as an
    // avgFrameBytes/maxFrameBytes spike with idrFramePercent > 0 on the same
    // second the input idle→active edge fires. All nil until at least one sized
    // frame this window.
    /// Average network-delivered frame size this window, in bytes.
    public var avgFrameBytes: Double?
    /// Largest single network-delivered frame this window, in bytes - the big
    /// IDR a resume can produce.
    public var maxFrameBytes: Int?
    /// Percentage of frames this window that were IDR keyframes. A nonzero value
    /// outside the very first frames is the recurring-IDR signature.
    public var idrFramePercent: Double?

    public init() {}

    /// Build the ordered row list for the overlay. `enabled` filters to
    /// just the rows the user (via Settings preset) wants to see;
    /// `targetFps` is the negotiated stream FPS used for FPS / decode-time
    /// health thresholds.
    ///
    /// Rows whose underlying snapshot field is `nil` still emit (so the
    /// user sees that the metric exists), but with an em-dash value and
    /// `neutral` health. Renderer-backpressure drops are NOT a row of
    /// their own - they fold into `decoderDrops` only when non-zero (see
    /// the doc on `rendererBackpressureDrops`), so the pipeline section
    /// stays uncluttered on healthy streams.
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
            .audio
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
            return StatsRow(
                kind: .renderFps, label: "Render",
                value: formatFps(renderedFps),
                symbolName: "display",
                health: fpsHealth(renderedFps, thresholds: thresholds),
                section: .frameRates)
        default:
            // .hostFps and any future frame-rate kind: host has no health
            // source (we report the configured rate as a proxy), so .neutral.
            return StatsRow(
                kind: .hostFps, label: "Host",
                value: formatFps(hostFps),
                symbolName: "desktopcomputer",
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
                value: formatMs(avgDecodeTimeMs),
                symbolName: "clock",
                health: decodeTimeHealth(avgDecodeTimeMs, targetFps: targetFps),
                section: .pipeline)
        case .hostProcessing:
            // "Host encode", NOT "latency": this is the HOST's capture+encode
            // time (Sunshine `frameHostProcessingLatency`), e.g. ~60ms with a
            // two-pass AV1 encode at high fps. It is server-side and must never
            // be read as our client/pipeline latency (the separate "Latency"
            // row is RTT; our pipeline e2e is ~6ms). Labelling it "Host encode"
            // removes the misread that the engine regressed.
            return StatsRow(
                kind: .hostProcessing, label: "Host encode",
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
        guard let fps else { return .neutral }
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
    /// Warn if decode wall-clock crosses half the frame budget,
    /// critical if it crosses 90% - at 60Hz that's >8.3ms warn,
    /// >15ms crit. Frame budget shrinks at higher FPS so the
    /// thresholds tighten automatically.
    private func decodeTimeHealth(_ decodeMs: Double?, targetFps: Double) -> StatsRow.Health {
        guard let decodeMs, targetFps > 0 else { return .neutral }
        let frameBudget = 1000.0 / targetFps
        if decodeMs > frameBudget * 0.9 { return .critical }
        if decodeMs > frameBudget * 0.5 { return .warning }
        return .healthy
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
