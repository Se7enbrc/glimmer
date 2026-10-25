// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

public struct StreamStatsSnapshot: Sendable {
    /// The codec selected for this connection, not the PC's configured preference.
    public var videoCodec: String?
    /// Estimated PC capture rate, excluding untimed repeats once timing is available.
    /// Falls back to measured reception without timing support. Captured desktop
    /// updates can differ from the game's own render rate.
    public var hostFps: Double?
    /// Negotiated stream limit, kept separate from measured rates for chart targets.
    public var configuredFps: Double?
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
    public var rttMs: Double?
    /// Variance of the RTT estimate, in milliseconds, from
    /// `LiGetEstimatedRttInfo`. `Double` for the same decimal-resolution reason.
    public var rttVarianceMs: Double?

    /// Network jitter in milliseconds - variation in packet inter-arrival time.
    public var jitterMs: Double?

    /// EMA of decoder wall-clock time per frame, in milliseconds (time
    /// between `VTDecompressionSessionDecodeFrame` submission and the
    /// matching decompression-output callback fire).
    public var avgDecodeTimeMs: Double?
    /// `avgDecodeTimeMs` split into VT service time and queue wait behind the prior frame.
    public var avgDecodeServiceMs: Double?
    public var avgDecodeWaitMs: Double?

    /// Host-side capture + encode latency, in milliseconds, as reported by Sunshine on each DECODE_UNIT
    /// (`frameHostProcessingLatency` in Limelight.h - 1/10 ms units on the wire, converted to ms here).
    public var minHostProcessingLatencyMs: Double?
    public var maxHostProcessingLatencyMs: Double?
    public var avgHostProcessingLatencyMs: Double?

    /// Configured / negotiated stream bitrate in Mbps. This is the rate
    /// the host was asked to encode at - the "headline" bitrate the user
    /// configured. Useful as a baseline next to the measured number.
    public var negotiatedBitrateMbps: Double?
    /// Measured bytes-into-VideoToolbox over the last sampling window, converted to Mbps.
    public var measuredBitrateMbps: Double?

    /// Total renderer-backpressure drops since the session started.
    public var rendererBackpressureDrops: UInt64?

    /// Absolute session-cumulative decoder-side drop count (VT rejected, plus pre-VT discards now credited
    /// via `recordDecoderDiscard`).
    public var decoderDropCount: UInt64?

    // ---- Frame-pacer smoothness -------------------------------------------  Populated from the
    // StatsCollector pacer counters.

    /// Live pacing-queue depth: frames buffered in the pacer waiting for a
    /// vsync, sampled at the display's tick rate. 1-2 is the healthy target;
    /// a sustained 3 means we're riding the cap (latency creeping up).
    public var pacingQueueDepth: Int?
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
    /// Total frames the pacer dropped because it could not present them in time (jitter-buffer overflow /
    /// sustained-lag trim).
    public var presentationLateDrops: UInt64?
    /// Perceived present gaps (renderer showed nothing fresh) - the badge's
    /// felt-stutter signal. Session-cumulative; catch-up discards don't count.
    public var presentationGaps: UInt64?

    /// Source channel layout for the active session, nil before it starts.
    /// Playback adapts that source to the current speakers or headphones.
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

    // ---- Frame size + type (telemetry only; no overlay row) -----------------  Window-relative per-frame
    // byte size + IDR fraction, surfaced ONLY by the opt-in telemetry exporter (not rendered in the overlay).
    public var avgFrameBytes: Double?
    /// Largest single network-delivered frame this window, in bytes - the big
    /// IDR a resume can produce.
    public var maxFrameBytes: Int?
    /// Percentage of frames this window that were IDR keyframes. A nonzero value
    /// outside the very first frames is the recurring-IDR signature.
    public var idrFramePercent: Double?
    /// Host frame cadence this window (telemetry only; see StatsCollector.HostCadence).
    package var hostCadence: StatsCollector.HostCadence?

    public init() {}

    /// Build the ordered row list for the overlay.
}
