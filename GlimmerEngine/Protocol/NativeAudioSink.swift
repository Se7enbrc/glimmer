// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

/// Receives post-FEC, decrypted Opus bytes and explicit loss concealment requests.
/// AudioDecoder owns decode and HAL playout; the backend sink lacks an explicit concealment entry point.
package protocol NativeAudioSink: AnyObject, Sendable {
    /// Configure the opus decoder + audio engine. Returns 0 on success.
    /// `opus` is the negotiated multistream config; `audioConfig` is the
    /// GFE/Sunshine channel-layout code.
    func initialize(audioConfig: Int32, opus: OpusConfig) -> Int32
    /// Decode + play one opus packet (raw bytes, after FEC + any decrypt), valid only for the call.
    func decodeAndPlay(_ opus: UnsafeRawBufferPointer)
    /// Packet-loss concealment for one unrecovered/missing frame: the decoder
    /// conceals the gap (AudioStream.c:166-169).
    func decodeAndPlayPLC()
    /// Tear down the decoder + engine.
    func cleanup()
    /// Packet flow RESUMED after a multi-second arrival gap (host-idle silence,
    /// nap). Hygiene hook - the sink may re-arm its playout state so stale
    /// segment anchors don't survive the gap; the default does nothing. Called
    /// on the decode worker, so implementations must make NO AV calls.
    func notePacketFlowResumed(afterGapMs: Double)
    /// The inter-arrival gap that ended with the newest datagram. Called per
    /// datagram on the decode worker, so implementations must make NO AV calls.
    func noteArrivalGap(nanos: UInt64)
}

extension NativeAudioSink {
    package func notePacketFlowResumed(afterGapMs: Double) {}
    package func noteArrivalGap(nanos: UInt64) {}
}
