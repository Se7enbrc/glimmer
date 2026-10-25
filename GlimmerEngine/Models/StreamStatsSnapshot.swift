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

    /// ENet round-trip time in milliseconds; Double preserves future sub-millisecond readings.
    public var rttMs: Double?
    /// Variance of the RTT estimate, in milliseconds, from
    /// `LiGetEstimatedRttInfo`. `Double` for the same decimal-resolution reason.
    public var rttVarianceMs: Double?

    /// RFC 3550 smoothed RTP inter-arrival deviation, in milliseconds.
    /// Sampled on the receive thread; Double retains sub-millisecond jitter.
    public var jitterMs: Double?

    /// EMA of decoder wall-clock time per frame, in milliseconds (time
    /// between `VTDecompressionSessionDecodeFrame` submission and the
    /// matching decompression-output callback fire).
    public var avgDecodeTimeMs: Double?
    /// `avgDecodeTimeMs` split into VT service time and queue wait behind the prior frame.
    public var avgDecodeServiceMs: Double?
    public var avgDecodeWaitMs: Double?

    /// PC capture and encode time in milliseconds, converted from Sunshine's tenth-ms field.
    /// Min, max and mean cover nonzero reports in the current window; zero repeat reports are excluded.
    public var minHostProcessingLatencyMs: Double?
    public var maxHostProcessingLatencyMs: Double?
    public var avgHostProcessingLatencyMs: Double?

    /// Configured / negotiated stream bitrate in Mbps. This is the rate
    /// the host was asked to encode at - the "headline" bitrate the user
    /// configured. Useful as a baseline next to the measured number.
    public var negotiatedBitrateMbps: Double?
    /// Video bytes received during the sampling window, converted to Mbps.
    public var measuredBitrateMbps: Double?

    /// Session-cumulative renderer-queue rejections, separate from decoder and pacing drops.
    /// Hidden at zero so healthy streams do not gain an empty row.
    public var rendererBackpressureDrops: UInt64?

    /// Session-cumulative VT rejections and pre-VT discards, used by the drops-by-cause row.
    public var decoderDropCount: UInt64?

    // Cadence counters capture uneven delivery that average FPS can hide.

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
    /// Session-cumulative pacing drops caused by overflow or sustained-lag trimming.
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

    // Frame size and IDR fraction are telemetry-only signals for large-frame bursts.
    /// Average network-delivered frame size this window, in bytes.
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
}
