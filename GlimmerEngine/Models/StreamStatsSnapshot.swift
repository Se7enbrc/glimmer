// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

@usableFromInline package struct StreamStatsSnapshot: Sendable {
    /// The codec selected for this connection, not the PC's configured preference.
    @usableFromInline package var videoCodec: String?
    /// Estimated PC capture rate, excluding untimed repeats once timing is available.
    /// Falls back to measured reception without timing support. Captured desktop
    /// updates can differ from the game's own render rate.
    @usableFromInline package var hostFps: Double?
    /// Negotiated stream limit, kept separate from measured rates for chart targets.
    @usableFromInline package var configuredFps: Double?
    /// Incoming frame rate from the network - the rate at which decode units
    /// land in our `submitDecodeUnit` callback (after the native receiver
    /// depacketizes and reassembles each frame).
    @usableFromInline package var receivedFps: Double?
    /// Decoding frame rate - successful VT decode-output callbacks per
    /// second.
    @usableFromInline package var decodedFps: Double?
    /// Rendering frame rate - `AVSampleBufferVideoRenderer.enqueue` calls
    /// per second. Once enqueued, the OS owns v-sync pacing.
    @usableFromInline package var renderedFps: Double?

    /// Frames dropped by the network connection, as a percentage of total
    /// frames. We don't surface this number yet, so we leave it nil and
    /// render as "-".
    @usableFromInline package var networkDroppedPercent: Double?
    /// Frames dropped by the decoder (VT reported `kVTDecodeInfo_FrameDropped`
    /// in its output callback), as a percentage of frames the decoder saw.
    @usableFromInline package var decoderDroppedPercent: Double?

    /// Average network RTT in milliseconds, from `LiGetEstimatedRttInfo`.
    /// `Double` (not `UInt32`) so the overlay shows decimal ms - at ~6ms e2e a
    /// whole-ms RTT reads with ±halfms blur that hides the signal. The ENet
    /// estimate is whole-ms on the wire today, but plumbing it as Double lets a
    /// finer RTT source surface without a type change and keeps the formatter
    /// uniform with jitter.
    @usableFromInline package var rttMs: Double?
    /// Variance of the RTT estimate, in milliseconds, from
    /// `LiGetEstimatedRttInfo`. `Double` for the same decimal-resolution reason.
    @usableFromInline package var rttVarianceMs: Double?

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
    @usableFromInline package var jitterMs: Double?

    /// EMA of decoder wall-clock time per frame, in milliseconds (time
    /// between `VTDecompressionSessionDecodeFrame` submission and the
    /// matching decompression-output callback fire).
    @usableFromInline package var avgDecodeTimeMs: Double?
    /// `avgDecodeTimeMs` split into VT service time and queue wait behind the prior frame.
    @usableFromInline package var avgDecodeServiceMs: Double?
    @usableFromInline package var avgDecodeWaitMs: Double?

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
    @usableFromInline package var minHostProcessingLatencyMs: Double?
    @usableFromInline package var maxHostProcessingLatencyMs: Double?
    @usableFromInline package var avgHostProcessingLatencyMs: Double?

    /// Configured / negotiated stream bitrate in Mbps. This is the rate
    /// the host was asked to encode at - the "headline" bitrate the user
    /// configured. Useful as a baseline next to the measured number.
    @usableFromInline package var negotiatedBitrateMbps: Double?
    /// Measured bytes-into-VideoToolbox over the last sampling window,
    /// converted to Mbps. The actual rate the host is currently
    /// transmitting, which can dip well below the configured bitrate when
    /// the scene is mostly static.
    @usableFromInline package var measuredBitrateMbps: Double?

    /// Total renderer-backpressure drops since the session started.
    /// AVSampleBufferVideoRenderer dropped these frames because its
    /// internal queue was full (`isReadyForMoreMediaData == false`).
    /// Tracked separately from decoder drops because the failure mode is
    /// different: this is "OS-side queue got full, we're behind on
    /// display" not "VT rejected the bitstream". Surfaced in the overlay
    /// only when non-zero - a healthy stream stays at 0 and we don't want
    /// to add a row of clutter for the common case.
    @usableFromInline package var rendererBackpressureDrops: UInt64?

    /// Absolute session-cumulative decoder-side drop count (VT rejected, plus
    /// pre-VT discards now credited via `recordDecoderDiscard`). The
    /// `decoderDroppedPercent` row shows the percentage; this raw count feeds the
    /// dedicated three-way drops-by-cause line so each cause shows a real number
    /// instead of two of them hiding in suffixes.
    @usableFromInline package var decoderDropCount: UInt64?

    // ---- Frame-pacer smoothness -------------------------------------------
    //
    // Populated from the StatsCollector pacer counters. These describe how
    // evenly frames are reaching the screen - the buttery-smooth-pass signal
    // that the FPS rows alone can't show (you can hit 60 rendered fps and
    // still judder if the presents are unevenly spaced).

    /// Live pacing-queue depth: frames buffered in the pacer waiting for a
    /// vsync, sampled at the display's tick rate. 1-2 is the healthy target;
    /// a sustained 3 means we're riding the cap (latency creeping up).
    @usableFromInline package var pacingQueueDepth: Int?
    /// Average magnitude of present-vs-PTS cadence error this window, in ms.
    /// The headline smoothness number: how far each present landed from the
    /// ideal grid. Near zero = buttery; growth = judder.
    @usableFromInline package var avgPresentCadenceErrorMs: Double?
    /// Worst present-vs-PTS cadence error this window, in ms - the spike a
    /// user perceives as a hitch.
    @usableFromInline package var maxPresentCadenceErrorMs: Double?
    /// Percentage of presents this window that landed on-cadence (within the
    /// collector's perceptual tolerance). 100% = perfectly paced.
    @usableFromInline package var onTimePresentPercent: Double?
    /// Total frames the pacer dropped because it could not present them in
    /// time (jitter-buffer overflow / sustained-lag trim). The NEW third drop
    /// cause, distinct from decoder and renderer-backpressure drops. Session-
    /// cumulative; surfaced in the Smoothness row's suffix when non-zero.
    @usableFromInline package var presentationLateDrops: UInt64?
    /// Perceived present gaps (renderer showed nothing fresh) - the badge's
    /// felt-stutter signal. Session-cumulative; catch-up discards don't count.
    @usableFromInline package var presentationGaps: UInt64?

    /// Source channel layout for the active session, nil before it starts.
    /// Playback adapts that source to the current speakers or headphones.
    @usableFromInline package var audioConfigDescription: String?

    /// Mac-side host vitals sampled per-tick from `MacSystemStats.shared`.
    /// All nil-able so a probe failure (or a desktop with no battery)
    /// surfaces as em-dash instead of "0%".
    @usableFromInline package var macBatteryPercent: Int?
    @usableFromInline package var macBatteryCharging: Bool?
    @usableFromInline package var macCpuPercent: Double?
    @usableFromInline package var macRamPercent: Double?

    /// Connected game-controller battery (first attached pad reporting one).
    /// Nil when no controller is attached or the pad doesn't expose a battery
    /// (wired pads, or pads GameController can't read) - renders as em-dash.
    @usableFromInline package var controllerBatteryPercent: Int?
    @usableFromInline package var controllerBatteryCharging: Bool?

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
    @usableFromInline package var avgFrameBytes: Double?
    /// Largest single network-delivered frame this window, in bytes - the big
    /// IDR a resume can produce.
    @usableFromInline package var maxFrameBytes: Int?
    /// Percentage of frames this window that were IDR keyframes. A nonzero value
    /// outside the very first frames is the recurring-IDR signature.
    @usableFromInline package var idrFramePercent: Double?
    /// Host frame cadence this window (telemetry only; see StatsCollector.HostCadence).
    @usableFromInline package var hostCadence: StatsCollector.HostCadence?

    @usableFromInline package init() {}

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
}
