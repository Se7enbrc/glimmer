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
    struct DecodeState: Sendable {
        /// True iff VT confirmed it is using a HARDWARE-accelerated decoder
        /// (the `kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder`
        /// property read back from the live session). We REQUIRE hardware at
        /// session-create, so this should always be true - surfacing it makes a
        /// silent software-fallback (an OS/driver regression) immediately visible.
        var hwDecode: Bool
        /// Negotiated video codec ("av1" / "hevc" / "h264"), derived from the
        /// stream format mask. The label that lets a multi-host capture answer
        /// "did this session actually go AV1?" - HEVC Main10 and AV1 Main10 are
        /// otherwise indistinguishable on bit-depth/colorspace/pixel-format.
        var codec: String
        /// Live output pixel format as a FourCC string (e.g. "x420" = 10-bit
        /// video-range 4:2:0 biplanar, "420v" = 8-bit). The decode-side truth of
        /// what the layer composites.
        var pixelFormat: String
        /// Output bit depth (8 or 10), derived from the negotiated stream format.
        var bitDepth: Int
        /// Effective colorspace key the decode path attached this frame
        /// ("itur_2100_PQ" / "itur_2020" / "itur_709" / "srgb").
        var colorSpaceKey: String
    }

    /// Publish the live DECODE state. Called off the hot path - the decode queue
    /// stamps it at VT-session create and on a colorspace change (both rare).
    func setDecodeState(_ state: DecodeState) {
        os_unfair_lock_lock(decodeStateLock); decodeStateValue = state; os_unfair_lock_unlock(decodeStateLock)
    }
    /// Latest DECODE state, or nil before the first decoded frame. Read by the
    /// exporter on its 1Hz queue (never the hot path).
    var decodeState: DecodeState? {
        os_unfair_lock_lock(decodeStateLock); defer { os_unfair_lock_unlock(decodeStateLock) }
        return decodeStateValue
    }

    /// Publish the latest inter-packet-gap distribution. Called once per ~2s
    /// receive-metrics window by the RTP path - never the hot per-datagram path.
    func setPacketGap(_ gap: PacketGapSnapshot) {
        os_unfair_lock_lock(gapLock); packetGapValue = gap; os_unfair_lock_unlock(gapLock)
    }
    /// Latest inter-packet-gap distribution, or nil before the first window. Read
    /// by the exporter on its 1Hz queue (never the hot path).
    var packetGap: PacketGapSnapshot? {
        os_unfair_lock_lock(gapLock); defer { os_unfair_lock_unlock(gapLock) }
        return packetGapValue
    }

    /// Live FEC-HEALTH gauge: the FecHeadroomController's RESPONSE (the reorder-
    /// hold it is holding + both headroom axes) plus the per-frame parity headroom,
    /// published once per ~2s receive-metrics window by the RTP path. READ-ONLY
    /// observability - none of these values feed back into the FEC/reorder logic;
    /// they let a degrading link be SEEN on the dashboard (the controller's
    /// transitions were previously diag-log-only). Last-writer-wins behind one lock,
    /// the same idiom as `packetGap`. nil before the first window.
    struct FecHealthSnapshot: Sendable {
        /// Live reorder-hold window the queue applies (ms): base 24, cap 48 - the
        /// controller's combined response to jitter + loss.
        var reorderHoldMs: Double
        /// Jitter axis level (0 on a clean link). ooo/retransmit ride the separate
        /// reorder axis; direct loss the loss axis - both fold into the live hold.
        var headroomLevel: Int
        /// Direct-loss axis level (0 on a clean link).
        var lossLevel: Int
        /// Host-driven per-frame FEC percentage of the latest frame.
        var fecPercentage: Int
        /// Spare parity shards on the WORST FEC-RECOVERED frame this window (parity −
        /// data deficit) - the early warning before a frame goes unrecoverable. nil
        /// with NO recovery: "full parity, nothing consumed" is not a near-miss.
        var parityMargin: Int?
    }

    /// Publish the FEC-health gauge. Called once per ~2s window by the RTP receive
    /// path (never the per-datagram hot path).
    func setFecHealth(_ snapshot: FecHealthSnapshot) {
        os_unfair_lock_lock(fecHealthLock); fecHealthValue = snapshot; os_unfair_lock_unlock(fecHealthLock)
    }
    /// Latest FEC-health gauge, or nil before the first window. Read by the
    /// exporter on its 1Hz queue (never the hot path).
    var fecHealth: FecHealthSnapshot? {
        os_unfair_lock_lock(fecHealthLock); defer { os_unfair_lock_unlock(fecHealthLock) }
        return fecHealthValue
    }

    /// AWDL-helper gauge: awdl0 parked this stream + how many times macOS re-raised
    /// it (the contention rate the routing-socket suppressor fights). nil when off.
    struct AWDLHelperSnapshot: Sendable {
        var suppressing: Bool
        var reSuppressTotal: UInt64
    }
    func setAWDLHelper(_ snapshot: AWDLHelperSnapshot) { awdlHelperState.withLock { $0 = snapshot } }
    var awdlHelper: AWDLHelperSnapshot? { awdlHelperState.withLock { $0 } }

    func setRecvJitterMs(_ ms: Double) {
        os_unfair_lock_lock(jitterLock); recvJitterMsValue = ms; os_unfair_lock_unlock(jitterLock)
    }
    var recvJitterMs: Double {
        os_unfair_lock_lock(jitterLock); defer { os_unfair_lock_unlock(jitterLock) }
        return recvJitterMsValue
    }

    /// Refresh the live RTT gauge (ms). Called once per ~1Hz telemetry tick by
    /// the exporter - never the hot path.
    func setRttMs(_ ms: Double) {
        os_unfair_lock_lock(rttLock); rttMsValue = ms; os_unfair_lock_unlock(rttLock)
    }
    /// Current smoothed RTT (ms), 0 if none yet. Read by the per-frame
    /// glass-to-glass computation at present (one short lock; only on the
    /// gate-on telemetry path).
    var rttMs: Double {
        os_unfair_lock_lock(rttLock); defer { os_unfair_lock_unlock(rttLock) }
        return rttMsValue
    }

    /// Stamp the latest VTDecompressionSessionCreate wall-clock cost (ms).
    /// Called by the decode queue at each create (rare) - never the hot path.
    func setVtSessionCreateMs(_ ms: Double) {
        os_unfair_lock_lock(vtSessionCreateLock); vtSessionCreateMsValue = ms
        os_unfair_lock_unlock(vtSessionCreateLock)
    }
    /// Latest VT-session create cost (ms), 0 if none yet. Read by the exporter on
    /// its 1Hz queue (never the hot path).
    var vtSessionCreateMs: Double {
        os_unfair_lock_lock(vtSessionCreateLock); defer { os_unfair_lock_unlock(vtSessionCreateLock) }
        return vtSessionCreateMsValue
    }

    /// Fold one applied Cruise gain into the per-session max (1.0 = unboosted).
    /// Called from the mouse-batch path; cheap last-writer-max under the lock.
    func noteCruiseGain(_ g: Double) {
        os_unfair_lock_lock(cruiseMaxGainLock)
        if g > cruiseMaxGainValue { cruiseMaxGainValue = g }
        os_unfair_lock_unlock(cruiseMaxGainLock)
    }
    /// Largest Cruise gain applied this session (1.0 if never boosted). Read by
    /// the exporter on its 1Hz queue (never the hot path).
    var cruiseMaxGain: Double {
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
    func setPresentSuppressed(_ suppressed: Bool) {
        os_unfair_lock_lock(presentSuppressedLock)
        let wasSuppressed = presentSuppressedValue
        presentSuppressedValue = suppressed
        os_unfair_lock_unlock(presentSuppressedLock)
        if wasSuppressed && !suppressed {
            FrameTimingTracker.shared?.armResumePresentTag()
        }
    }
    /// Current present-suppression state. Read by the exporter on its 1Hz queue
    /// (never the hot path).
    var presentSuppressed: Bool {
        os_unfair_lock_lock(presentSuppressedLock); defer { os_unfair_lock_unlock(presentSuppressedLock) }
        return presentSuppressedValue
    }

    /// Set/clear the decode-gate gauge. Called at the gate's engage/lift edges
    /// by VideoDecoder (already-rare sites, never per frame) - the mirror of
    /// `setPresentSuppressed` for the third hidden-window state.
    func setDecodeGated(_ gated: Bool) {
        os_unfair_lock_lock(decodeGatedLock)
        decodeGatedValue = gated
        os_unfair_lock_unlock(decodeGatedLock)
    }
    /// Current decode-gate state. Read by the exporter on its 1Hz queue (never
    /// the hot path).
    var decodeGated: Bool {
        os_unfair_lock_lock(decodeGatedLock); defer { os_unfair_lock_unlock(decodeGatedLock) }
        return decodeGatedValue
    }

    /// Stamp the pacer-tick REALTIME gauge. Called once at tick-thread start by
    /// PacerTickThread (RT-applied success/failure, or the flag-off path) - never
    /// per frame.
    func setPacerTickRealtime(_ applied: Bool) {
        os_unfair_lock_lock(pacerTickRealtimeLock)
        pacerTickRealtimeValue = applied
        os_unfair_lock_unlock(pacerTickRealtimeLock)
    }
    /// Current pacer-tick realtime state. Read by the exporter on its 1Hz queue
    /// (never the hot path).
    var pacerTickRealtime: Bool {
        os_unfair_lock_lock(pacerTickRealtimeLock); defer { os_unfair_lock_unlock(pacerTickRealtimeLock) }
        return pacerTickRealtimeValue
    }

    // MARK: - Ignored-control per-type tallies

    /// One-call contract for the inbound-control default arm: bump the
    /// aggregate `ctrlIgnoredTotal` AND the per-type tally together so the two
    /// can never skew. EnetControlChannel swaps its bare
    /// `ctrlIgnoredTotal.increment()` for this. A small-dict hash add on the
    /// low-rate control path - not the video/audio datagram path.
    func noteCtrlIgnored(type: UInt16) {
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
final class CtrlIgnoredPerType: @unchecked Sendable {
    /// Cap on distinct tracked types - far above the observed 1-3, small enough
    /// that a hostile/buggy host spraying fresh type words can't grow the map.
    static let maxTrackedTypes = 16

    private let lock = os_unfair_lock_t.allocate(capacity: 1)
    private var counts: [UInt16: UInt64] = [:]
    init() { lock.initialize(to: os_unfair_lock_s()) }
    deinit { lock.deallocate() }

    func increment(type: UInt16) {
        os_unfair_lock_lock(lock)
        if counts[type] != nil || counts.count < Self.maxTrackedTypes {
            counts[type, default: 0] &+= 1
        }
        os_unfair_lock_unlock(lock)
    }
    /// Current per-type totals. Read by the scorecard at stop (and safe at 1Hz).
    var totals: [UInt16: UInt64] {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        return counts
    }
    func reset() {
        os_unfair_lock_lock(lock); counts = [:]; os_unfair_lock_unlock(lock)
    }
}
