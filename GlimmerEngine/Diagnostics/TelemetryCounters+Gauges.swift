// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  TelemetryCounters+Gauges.swift
//
//  The video/network/present gauge accessors: live DECODE state, inter-packet
//  gap distribution, smoothed recv jitter, smoothed RTT, the present-
//  suppression + decode-gate flags, and the per-type ignored-control store.
//  Split out of TelemetryCounters.swift to keep that file under the length
//  limit (pure move, same idiom as the FramePacer split). The stored
//  gauge state (the locks + values) stays on the class in
//  TelemetryCounters.swift - stored properties cannot live in extensions.
//

import Foundation
import os

extension TelemetryCounters {

    // MARK: - Decode / packet-gap / jitter / RTT / present-suppression gauges

    /// Live DECODE-side STATE (signal: DECODE) - what VideoToolbox is actually
    /// producing right now: the HW-accelerated-decoder confirmation, the live
    /// pixel format (FourCC string) + bit depth, and the effective colorspace key.
    /// Published off the hot path (the decode queue stamps it when the VT session
    /// is created / the colorspace changes - both already-rare sites) and read at
    /// 1Hz by the exporter. A plain value struct behind an unfair lock:
    /// last-writer-wins is correct for a 1Hz-sampled state gauge, and the lock
    /// keeps the multi-field read tear-free. nil before the first decoded frame.
    /// (Type lives here with its accessors; the lock + value storage stay on the
    /// class in TelemetryCounters.swift - stored properties can't move.)
    package struct DecodeState: Sendable {

        package init(
            hwDecode: Bool,
            codec: String,
            pixelFormat: String,
            bitDepth: Int,
            colorSpaceKey: String
        ) {
            self.hwDecode = hwDecode
            self.codec = codec
            self.pixelFormat = pixelFormat
            self.bitDepth = bitDepth
            self.colorSpaceKey = colorSpaceKey
        }

        /// True iff VT confirmed it is using a HARDWARE-accelerated decoder
        /// (the `kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder`
        /// property read back from the live session). We REQUIRE hardware at
        /// session-create, so this should always be true - surfacing it makes a
        /// silent software-fallback (an OS/driver regression) immediately visible.
        package var hwDecode: Bool
        /// Negotiated video codec ("av1" / "hevc" / "h264"), derived from the
        /// stream format mask. The label that lets a multi-host capture answer
        /// "did this session actually go AV1?" - HEVC Main10 and AV1 Main10 are
        /// otherwise indistinguishable on bit-depth/colorspace/pixel-format.
        package var codec: String
        /// Live output pixel format as a FourCC string (e.g. "x420" = 10-bit
        /// video-range 4:2:0 biplanar, "420v" = 8-bit). The decode-side truth of
        /// what the layer composites.
        package var pixelFormat: String
        /// Output bit depth (8 or 10), derived from the negotiated stream format.
        package var bitDepth: Int
        /// Resolved input description: primaries, transfer, matrix, output range and optional gamma.
        /// "pending" until the first frame resolves; independent of display EDR headroom.
        package var colorSpaceKey: String
    }

    /// Publish the live DECODE state. Called off the hot path - the decode queue
    /// stamps it at VT-session create and on a colorspace change (both rare).
    package func setDecodeState(_ state: DecodeState) {
        os_unfair_lock_lock(decodeStateLock); decodeStateValue = state; os_unfair_lock_unlock(decodeStateLock)
    }
    /// Latest DECODE state, or nil before the first decoded frame. Read by the
    /// exporter on its 1Hz queue (never the hot path).
    package var decodeState: DecodeState? {
        os_unfair_lock_lock(decodeStateLock); defer { os_unfair_lock_unlock(decodeStateLock) }
        return decodeStateValue
    }

    /// Publish the latest inter-packet-gap distribution. Called once per ~2s
    /// receive-metrics window by the RTP path - never the hot per-datagram path.
    package func setPacketGap(_ gap: PacketGapSnapshot) {
        os_unfair_lock_lock(gapLock); packetGapValue = gap; os_unfair_lock_unlock(gapLock)
    }
    /// Latest inter-packet-gap distribution, or nil before the first window. Read
    /// by the exporter on its 1Hz queue (never the hot path).
    package var packetGap: PacketGapSnapshot? {
        os_unfair_lock_lock(gapLock); defer { os_unfair_lock_unlock(gapLock) }
        return packetGapValue
    }

    /// Live FEC-HEALTH gauge: the host's FEC percentage and the per-frame parity
    /// headroom, published once per ~2s receive window by the RTP path. Read-only
    /// observability; last-writer-wins behind one lock. nil before the first window.
    package struct FecHealthSnapshot: Sendable {

        package init(
            fecPercentage: Int,
            parityMargin: Int? = nil
        ) {
            self.fecPercentage = fecPercentage
            self.parityMargin = parityMargin
        }

        /// Host-driven per-frame FEC percentage of the latest frame.
        package var fecPercentage: Int
        /// Spare parity shards on the WORST FEC-RECOVERED frame this window (parity −
        /// data deficit) - the early warning before a frame goes unrecoverable. nil
        /// with NO recovery: "full parity, nothing consumed" is not a near-miss.
        package var parityMargin: Int?
    }

    /// Publish the FEC-health gauge. Called once per ~2s window by the RTP receive
    /// path (never the per-datagram hot path).
    package func setFecHealth(_ snapshot: FecHealthSnapshot) {
        os_unfair_lock_lock(fecHealthLock); fecHealthValue = snapshot; os_unfair_lock_unlock(fecHealthLock)
    }
    /// Latest FEC-health gauge, or nil before the first window. Read by the
    /// exporter on its 1Hz queue (never the hot path).
    package var fecHealth: FecHealthSnapshot? {
        os_unfair_lock_lock(fecHealthLock); defer { os_unfair_lock_unlock(fecHealthLock) }
        return fecHealthValue
    }

    /// REORDER-DISPLACEMENT gauge: session-max lateness of reordered packets
    /// (ms + packets) and the live hold, so the exporter emits the invariant
    /// margin (hold − max) without touching the receive thread. Published each
    /// ~2s window from RtpVideoQueue; nil before the first window.
    package struct ReorderDisplacementSnapshot: Sendable {

        package init(
            maxMs: Double,
            maxPackets: Int,
            holdMs: Double
        ) {
            self.maxMs = maxMs
            self.maxPackets = maxPackets
            self.holdMs = holdMs
        }

        package var maxMs: Double
        package var maxPackets: Int
        package var holdMs: Double
    }
    package func setReorderDisplacement(_ snapshot: ReorderDisplacementSnapshot) {
        os_unfair_lock_lock(reorderDispLock); reorderDispValue = snapshot; os_unfair_lock_unlock(reorderDispLock)
    }
    /// Latest reorder-displacement gauge, or nil before the first window. Read
    /// by the exporter on its 1Hz queue.
    package var reorderDisplacement: ReorderDisplacementSnapshot? {
        os_unfair_lock_lock(reorderDispLock); defer { os_unfair_lock_unlock(reorderDispLock) }
        return reorderDispValue
    }

    /// AWDL-helper gauge: awdl0 parked this stream + how many times macOS re-raised
    /// it (the contention rate the routing-socket suppressor fights). nil when off.
    package struct AWDLHelperSnapshot: Sendable {

        package init(
            suppressing: Bool,
            reSuppressTotal: UInt64
        ) {
            self.suppressing = suppressing
            self.reSuppressTotal = reSuppressTotal
        }

        package var suppressing: Bool
        package var reSuppressTotal: UInt64
    }
    package func setAWDLHelper(_ snapshot: AWDLHelperSnapshot) { awdlHelperState.withLock { $0 = snapshot } }
    package var awdlHelper: AWDLHelperSnapshot? { awdlHelperState.withLock { $0 } }

    package func setRecvJitterMs(_ ms: Double) {
        os_unfair_lock_lock(jitterLock); recvJitterMsValue = ms; os_unfair_lock_unlock(jitterLock)
    }
    package var recvJitterMs: Double {
        os_unfair_lock_lock(jitterLock); defer { os_unfair_lock_unlock(jitterLock) }
        return recvJitterMsValue
    }

    /// Refresh the live RTT gauge (ms). Called once per ~1Hz telemetry tick by
    /// the exporter - never the hot path.
    package func setRttMs(_ ms: Double) {
        os_unfair_lock_lock(rttLock); rttMsValue = ms; os_unfair_lock_unlock(rttLock)
    }
    /// Current smoothed RTT (ms), 0 if none yet. Read by the per-frame
    /// glass-to-glass computation at present (one short lock; only on the
    /// gate-on telemetry path).
    package var rttMs: Double {
        os_unfair_lock_lock(rttLock); defer { os_unfair_lock_unlock(rttLock) }
        return rttMsValue
    }

    /// Stamp the latest VTDecompressionSessionCreate wall-clock cost (ms).
    /// Called by the decode queue at each create (rare) - never the hot path.
    package func setVtSessionCreateMs(_ ms: Double) {
        os_unfair_lock_lock(vtSessionCreateLock); vtSessionCreateMsValue = ms
        os_unfair_lock_unlock(vtSessionCreateLock)
    }
    /// Latest VT-session create cost (ms), 0 if none yet. Read by the exporter on
    /// its 1Hz queue (never the hot path).
    package var vtSessionCreateMs: Double {
        os_unfair_lock_lock(vtSessionCreateLock); defer { os_unfair_lock_unlock(vtSessionCreateLock) }
        return vtSessionCreateMsValue
    }

    /// Fold one applied Cruise gain into the per-session max (1.0 = unboosted).
    /// Called from the mouse-batch path; cheap last-writer-max under the lock.
    package func noteCruiseGain(_ g: Double) {
        os_unfair_lock_lock(cruiseMaxGainLock)
        if g > cruiseMaxGainValue { cruiseMaxGainValue = g }
        os_unfair_lock_unlock(cruiseMaxGainLock)
    }
    /// Largest Cruise gain applied this session (1.0 if never boosted). Read by
    /// the exporter on its 1Hz queue (never the hot path).
    package var cruiseMaxGain: Double {
        os_unfair_lock_lock(cruiseMaxGainLock); defer { os_unfair_lock_unlock(cruiseMaxGainLock) }
        return cruiseMaxGainValue
    }

    /// Set/clear the present-suppression gauge. Called at the suppression edges
    /// (backgrounded/occluded ↔ visible) by the present path - never per frame.
    /// The CLEAR edge also arms the latency rig's resume-present tag: the first
    /// present after un-suppress re-shows the retained frame, whose hold time
    /// (362.5ms session max) is a DESIGNED wait, not pipeline latency - tagging
    /// it keeps the o2p/g2g percentile feeds honest. Gate-checked single
    /// optional load when telemetry is off; at the connect-edge reset the
    /// tracker is already gone (stopped at prior teardown), so a reset-time
    /// true→false flip arms nothing.
    package func setPresentSuppressed(_ suppressed: Bool) {
        os_unfair_lock_lock(presentSuppressedLock)
        let wasSuppressed = presentSuppressedValue
        presentSuppressedValue = suppressed
        os_unfair_lock_unlock(presentSuppressedLock)
        if wasSuppressed && !suppressed {
            FrameTimingTracker.shared?.armResumePresentTag()
        }
    }
    /// Current present-suppression state. Read by the exporter on its 1Hz queue, and
    /// once per assembled frame by the latency tracker (telemetry on only).
    package var presentSuppressed: Bool {
        os_unfair_lock_lock(presentSuppressedLock); defer { os_unfair_lock_unlock(presentSuppressedLock) }
        return presentSuppressedValue
    }

    /// Set/clear the decode-gate gauge. Called at the gate's engage/lift edges
    /// by VideoDecoder (already-rare sites, never per frame) - the mirror of
    /// `setPresentSuppressed` for the third hidden-window state.
    package func setDecodeGated(_ gated: Bool) {
        os_unfair_lock_lock(decodeGatedLock)
        decodeGatedValue = gated
        os_unfair_lock_unlock(decodeGatedLock)
    }
    /// Current decode-gate state. Read by the exporter on its 1Hz queue, and once
    /// per assembled frame by the latency tracker (telemetry on only).
    package var decodeGated: Bool {
        os_unfair_lock_lock(decodeGatedLock); defer { os_unfair_lock_unlock(decodeGatedLock) }
        return decodeGatedValue
    }

    /// Stamp the pacer-tick REALTIME gauge. Called once at tick-thread start by
    /// PacerTickThread (RT-applied success/failure, or the flag-off path) - never
    /// per frame.
    package func setPacerTickRealtime(_ applied: Bool) {
        os_unfair_lock_lock(pacerTickRealtimeLock)
        pacerTickRealtimeValue = applied
        os_unfair_lock_unlock(pacerTickRealtimeLock)
    }
    /// Current pacer-tick realtime state. Read by the exporter on its 1Hz queue
    /// (never the hot path).
    package var pacerTickRealtime: Bool {
        os_unfair_lock_lock(pacerTickRealtimeLock); defer { os_unfair_lock_unlock(pacerTickRealtimeLock) }
        return pacerTickRealtimeValue
    }

    // MARK: - Ignored-control per-type tallies

    /// One-call contract for the inbound-control default arm: bump the
    /// aggregate `ctrlIgnoredTotal` AND the per-type tally together so the two
    /// can never skew. EnetControlChannel swaps its bare
    /// `ctrlIgnoredTotal.increment()` for this. A small-dict hash add on the
    /// low-rate control path - not the video/audio datagram path.
    package func noteCtrlIgnored(type: UInt16) {
        ctrlIgnoredTotal.increment()
        ctrlIgnoredPerType.increment(type: type)
    }
}

/// Per-TYPE tallies of ignored inbound CONTROL datagrams, keyed by the control
/// type word. DURABILITY is the point: the per-type totals previously lived
/// only in one teardown Diag NOTICE, which a crash or a still-running session
/// loses - here the session scorecard reads them at stop. Bounded
/// (`maxTrackedTypes`) so an unknown-type flood can't grow the map: overflow
/// types still count in the aggregate `ctrlIgnoredTotal`, they just don't gain
/// a per-type key (distinct types per session is ~1-3 in practice). Self-locked
/// like `P2State` so the rare control-path writes stay off every other
/// counter's lock.
package final class CtrlIgnoredPerType: @unchecked Sendable {
    /// Cap on distinct tracked types - far above the observed 1-3, small enough
    /// that a hostile/buggy host spraying fresh type words can't grow the map.
    package static let maxTrackedTypes = 16

    private let lock = os_unfair_lock_t.allocate(capacity: 1)
    private var counts: [UInt16: UInt64] = [:]
    package init() { lock.initialize(to: os_unfair_lock_s()) }
    deinit { lock.deallocate() }

    package func increment(type: UInt16) {
        os_unfair_lock_lock(lock)
        if counts[type] != nil || counts.count < Self.maxTrackedTypes {
            counts[type, default: 0] &+= 1
        }
        os_unfair_lock_unlock(lock)
    }
    /// Current per-type totals. Read by the scorecard at stop (and safe at 1Hz).
    package var totals: [UInt16: UInt64] {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        return counts
    }
    package func reset() {
        os_unfair_lock_lock(lock); counts = [:]; os_unfair_lock_unlock(lock)
    }
}
