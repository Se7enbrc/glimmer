//
//  RtpAudioReceiver+Telemetry.swift
//
//  The P1 AUDIO per-window receive-quality fold for the opt-in telemetry rig -
//  the audio analogue of RtpVideoQueue+ReceiveQuality.swift. Split out of
//  RtpAudioReceiver.swift so that file's type body stays under the SwiftLint
//  length limit; the window-state fields live on the receiver (`internal`) and
//  are touched only on its single receive thread (`recvQueue`), so this extension
//  needs no lock.
//
//  HOT-PATH SAFETY + GATING (load-bearing - zero-overhead when telemetry is OFF):
//  this runs on the audio receive thread once the ~1s window elapses, NOT per
//  packet, so the per-datagram path stays a straight decode. The only per-packet
//  cost the AUDIO signals add elsewhere is a single integer add for an unrecovered
//  PLC gap (audioLostInWindow). The totals folded here are the always-live
//  `TelemetryCounters` audio counters - unconditional integer adds at the rare
//  (~1Hz) flush site - which nothing READS unless the exporter is on. So with the
//  gate off (the default) the work here is: a cheap monotonic clock read + a
//  handful of integer adds once per second, and no allocation, no new lock.
//
//  SECRET-FREE: every value is a packet/loss/recovery count - nothing that could
//  carry a secret, key, or host identity.
//

import Foundation

extension RtpAudioReceiver {

    /// Fold this window's audio receive-quality into the always-live telemetry
    /// totals once per ~1s. Reads RtpAudioQueue's cumulative `Stats` (which it
    /// already maintains for free) + this receiver's per-window PLC-loss count, and
    /// publishes the DELTAS into the monotonic `TelemetryCounters` audio totals - so
    /// the per-packet path stays a straight decode and the exporter derives the
    /// per-second rates from the totals. On the receive thread only (no lock); the
    /// counters are only ever READ by the exporter when telemetry is on.
    func flushAudioMetricsIfDue() {
        let now = DispatchTime.now().uptimeNanoseconds
        if audioMetricsWindowStartNanos == 0 { audioMetricsWindowStartNanos = now }
        guard now &- audioMetricsWindowStartNanos >= Self.audioMetricsWindowNanos else { return }
        audioMetricsWindowStartNanos = now

        let stats = queue.stats
        let counters = TelemetryCounters.shared
        // Accepted audio packets + FEC-recovered shards: publish the cumulative
        // deltas (the stats counters are session-monotonic UInt32; the deltas are
        // small per window and wrap-safe via &-).
        let acceptedDelta = stats.packetCountAudio &- lastFlushedAudioPackets
        let recoveredDelta = stats.packetCountFecRecovered &- lastFlushedFecRecovered
        lastFlushedAudioPackets = stats.packetCountAudio
        lastFlushedFecRecovered = stats.packetCountFecRecovered
        if acceptedDelta > 0 { counters.audioPacketsTotal.increment(by: UInt64(acceptedDelta)) }
        if recoveredDelta > 0 { counters.audioFecRecoveredTotal.increment(by: UInt64(recoveredDelta)) }
        if audioLostInWindow > 0 {
            counters.audioPacketsLostTotal.increment(by: UInt64(audioLostInWindow))
            audioLostInWindow = 0
        }
    }
}
