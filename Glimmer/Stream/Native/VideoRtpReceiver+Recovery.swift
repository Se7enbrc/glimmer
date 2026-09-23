//
//  VideoRtpReceiver+Recovery.swift
//
//  Loss and key-frame bookkeeping on the video receive thread: each RFI loss
//  episode as one `loss_episode` event, each IDR as `idr_received`. Split from
//  VideoRtpReceiver.swift to keep it under the length budget.
//

import Foundation

/// One RFI loss episode: the first loss the depacketizer reports to the frame that
/// ends it (the host's recovery frame or an IDR). Frame numbers are wrap-safe u32.
struct VideoLossEpisode {

    struct Summary: Equatable {
        let firstFrame: UInt32
        let lastDiscarded: UInt32
        let recoveryFrame: UInt32
        /// RFIs that went out on the wire while the episode was open.
        let rfisSent: UInt64
        let recoveryMs: Double
        let byIDR: Bool

        /// Frames never shown: from the loss start up to the recovery frame.
        var discardedCount: UInt32 { recoveryFrame &- firstFrame }

        func eventFields(atNanos: UInt64) -> [String] {
            [
                "\"event\":\"loss_episode\"",
                "\"t_ns\":\(atNanos)",
                "\"first_frame\":\(firstFrame)",
                "\"last_discarded\":\(lastDiscarded)",
                "\"recovery_frame\":\(recoveryFrame)",
                "\"discarded_count\":\(discardedCount)",
                "\"rfis_sent\":\(rfisSent)",
                "\"recovery_ms\":" + TelemetryRenderer.jsonNumber(recoveryMs),
                "\"recovered_by\":\"\(byIDR ? "idr" : "rfi")\""
            ]
        }
    }

    private(set) var isOpen = false
    private var firstFrame: UInt32 = 0
    private var lastDiscarded: UInt32 = 0
    private var startNanos: UInt64 = 0
    private var rfiBaseline: UInt64 = 0

    /// A loss report for the RFI window `from...to`: opens an episode, or extends
    /// the open one. True when this report opened it.
    mutating func noteLoss(from: Int, to: Int, nowNanos: UInt64, rfisSent: UInt64) -> Bool {
        lastDiscarded = UInt32(truncatingIfNeeded: to)
        guard !isOpen else { return false }
        isOpen = true
        firstFrame = UInt32(truncatingIfNeeded: from)
        startNanos = nowNanos
        rfiBaseline = rfisSent
        return true
    }

    /// Close the open episode at the first frame assembled after it; nil if none is open.
    mutating func close(frame: Int32, isIDR: Bool, nowNanos: UInt64, rfisSent: UInt64) -> Summary? {
        guard isOpen else { return nil }
        isOpen = false
        return Summary(firstFrame: firstFrame, lastDiscarded: lastDiscarded,
                       recoveryFrame: UInt32(bitPattern: frame), rfisSent: rfisSent &- rfiBaseline,
                       recoveryMs: Double(nowNanos &- startNanos) / 1_000_000, byIDR: isIDR)
    }
}

extension VideoRtpReceiver {

    /// The `idr_received` row; `requested` when an IDR request or an RFI was outstanding.
    static func idrReceivedFields(frame: Int32, atNanos: UInt64, requested: Bool,
                                  roundTripMs: Double?, bytes: Int32) -> [String] {
        var fields = [
            "\"event\":\"idr_received\"",
            "\"t_ns\":\(atNanos)",
            "\"frame\":\(UInt32(bitPattern: frame))",
            "\"requested\":\(requested)",
            "\"bytes\":\(bytes)"
        ]
        if let roundTripMs { fields.append("\"round_trip_ms\":" + TelemetryRenderer.jsonNumber(roundTripMs)) }
        return fields
    }

    func depacketizerDetectedFrameLoss(from: Int, to: Int) {
        // One line when the episode opens; its summary logs at recovery.
        if lossEpisode.noteLoss(from: from, to: to, nowNanos: TelemetryCounters.monotonicNowNanos(),
                                rfisSent: TelemetryCounters.shared.rfiTotal.value) {
            Diag.info("NativeVideo frame loss from frame \(from) → RFI", Self.cat)
        }
        invalidateReferenceFrames(from, to)
    }

    /// End the open loss episode at the first frame assembled after it: one log
    /// line, one `loss_episode` row, and an rfi_recovery observation.
    func closeLossEpisode(at unit: DecodeUnit, isIDR: Bool) {
        let now = TelemetryCounters.monotonicNowNanos()
        guard let episode = lossEpisode.close(frame: unit.frameNumber, isIDR: isIDR, nowNanos: now,
                                              rfisSent: TelemetryCounters.shared.rfiTotal.value) else { return }
        FrameTimingTracker.shared?.rfiRecoveryMs.observe(episode.recoveryMs)
        Diag.notice("NativeVideo loss episode: \(episode.discardedCount) frames from \(episode.firstFrame), "
            + "recovered by \(isIDR ? "IDR" : "RFI") frame \(episode.recoveryFrame) after "
            + "\(String(format: "%.0f", episode.recoveryMs)) ms (\(episode.rfisSent) RFIs sent)", Self.cat)
        TelemetryExporter.recordLiveEvent(episode.eventFields(atNanos: now))
    }

    /// An IDR landed: resolve the explicit-IDR round trip when one was pending,
    /// and emit `idr_received`. Gate-on only, like the round-trip arm it pairs with.
    func noteKeyFrame(_ unit: DecodeUnit, tracker: FrameTimingTracker) {
        let now = TelemetryCounters.monotonicNowNanos()
        let roundTripMs = TelemetryCounters.shared.p2.resolveIdrArrival(now)
        if let roundTripMs {
            TelemetryCounters.shared.idrRoundTripMatchedTotal.increment()
            tracker.recordIdrRoundTrip(frameIndex: unit.frameNumber, roundTripMs: roundTripMs)
        }
        TelemetryExporter.recordLiveEvent(Self.idrReceivedFields(
            frame: unit.frameNumber, atNanos: now, requested: roundTripMs != nil || lossEpisode.isOpen,
            roundTripMs: roundTripMs, bytes: unit.fullLength))
    }
}
