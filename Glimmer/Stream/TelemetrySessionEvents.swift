//
//  TelemetrySessionEvents.swift
//
//  P2 SESSION-LIFECYCLE telemetry plumbing for the opt-in exporter, split out of
//  TelemetryCounters.swift so that file stays focused on the per-frame/per-event
//  counters + gauges and both stay under the file-length budget. Four signals
//  live here, all built on the SAME always-live-counter / 1Hz-read discipline as
//  the rest of the rig (see TelemetryCounters.swift for the gate/safety contract):
//
//    * CONNECT-HANDSHAKE breakdown - per-stage timing of the connect sequence
//      (RTSP → pairing/auth → ENet connect → first video frame), captured once
//      per session from the stage events the engine already fires, emitted to the
//      Prometheus body + the NDJSON (as an event line) + the session report.
//    * RECONNECT count + disconnect REASON - a monotonic reconnect counter and
//      the last terminate reason as an enum ordinal, captured at the
//      connection-terminated edge (always-live integer/enum store, off any hot
//      path - a terminate is the rarest event there is).
//    * IDR/RFI ROUND-TRIP - time from our requestIdrFrame/RFI SEND to the
//      resulting IDR/recovery frame ARRIVING. Both ends are client-side: we stamp
//      the send instant (gate-on only) and measure the delta when the IDR lands,
//      feeding a histogram + the per-frame trace.
//    * CORRUPTION/ARTIFACT heuristic - a cheap, sampled corruption counter
//      derived from signals the engine ALREADY computes (VT decode-status error /
//      FrameDropped bit, depacketizer discontinuity). NO per-pixel scan; the
//      detector is a hot-path-safe integer add at an already-rare event site.
//
//  GATING + HOT-PATH SAFETY (load-bearing): the counters/enum stores are
//  unconditional sub-µs integer/enum writes at already-rare lifecycle/recovery
//  sites (a connect stage edge, a terminate, an IDR request) - gating them would
//  buy nothing. The IDR-RTT SEND stamp is taken only when the latency tracker
//  exists (gate-on), so the OFF path pays one optional load. The handshake-stage
//  capture is a small map keyed by stage name, only touched on the (rare) stage
//  edges. Nothing here is on the per-frame decode/pace path, and nothing takes a
//  proven hot-path lock.
//
//  SECRET-FREE: every value is a millisecond duration, an integer count, an enum
//  ordinal, or a fixed stage label - nothing that could carry a secret/host id.
//

import Foundation
import os

// MARK: - Disconnect reason

/// Why a streaming session ended - a small CLOSED enum so the terminate cause is
/// a queryable ordinal/label rather than free text. Mapped from the engine's
/// terminate path: a clean stop, a host-initiated terminate with the moonlight
/// error code, a watchdog teardown (frame/present stall), or unknown. The exporter
/// emits BOTH the ordinal (a gauge, for thresholding) and the label (in an info
/// gauge / NDJSON string).
enum DisconnectReason: Int, Sendable {
    /// No terminate observed yet this session (the live default).
    case none = 0
    /// User asked to stop (quit hotkey / window close / app quit).
    case userStopped = 1
    /// Host told us the session is over with code 0 (clean host-side end).
    case hostClosedClean = 2
    /// Host terminated unexpectedly (non-zero moonlight terminate code).
    case hostError = 3
    /// Our frame/present watchdog tore the session down (decode/present stall).
    case watchdogStall = 4
    /// Connection never reached established (handshake failed / aborted).
    case connectFailed = 5
    /// The event-stream consumer was dropped (its `for await` loop ended /
    /// the AsyncStream's onTermination fired) rather than the user explicitly
    /// quitting. Distinct from `userStopped` so a reason-less teardown on a
    /// HEALTHY stream is no longer silently attributed to the user - the prior
    /// behaviour masked exactly this case (a dropped consumer reading as
    /// "user_stopped" in the scorecard).
    case consumerDropped = 6

    var label: String {
        switch self {
        case .none: return "none"
        case .userStopped: return "user_stopped"
        case .hostClosedClean: return "host_closed_clean"
        case .hostError: return "host_error"
        case .watchdogStall: return "watchdog_stall"
        case .connectFailed: return "connect_failed"
        case .consumerDropped: return "consumer_dropped"
        }
    }
}

// MARK: - Process-global disconnect tally (by reason)

/// PROCESS-GLOBAL, monotonic per-reason disconnect counters. One `Counter` per
/// `DisconnectReason` (excluding `.none`), incremented once per session at the
/// reason-latch site. Lives on the always-live `TelemetryCounters` singleton and
/// is DELIBERATELY kept out of `resetForNewSession`, so it survives the <1ms
/// exporter teardown that races the 1s scrape - the next session re-serves it.
/// `@unchecked Sendable`: each `Counter` is self-locked.
final class DisconnectReasonCounters: @unchecked Sendable {
    private let counters: [DisconnectReason: TelemetryCounters.Counter] = [
        .userStopped: .init(), .hostClosedClean: .init(), .hostError: .init(),
        .watchdogStall: .init(), .connectFailed: .init(), .consumerDropped: .init()
    ]
    func increment(_ reason: DisconnectReason) { counters[reason]?.increment() }
    /// Snapshot of (label, total) for every non-zero-defined reason, for the export.
    func snapshot() -> [(label: String, total: UInt64)] {
        counters.map { ($0.key.label, $0.value.value) }
    }
}

// MARK: - Click-to-first-frame latch (true click-to-pixels)

/// The TRUE click-to-pixels span the handshake breakdown can't see:
/// `handshake_total_ms` is anchored at connect-START (inside connectBackend), so
/// it EXCLUDES the serverinfo + launch + busy-poll legs that run between the
/// user's click and connect-start. This latch is anchored at the CLICK
/// (`MoonlightManager.stream()`) and resolved at the first decoded frame, both on
/// a wall clock (`Date`) the way the existing click anchor is - no cross-actor
/// monotonic plumbing, and it survives `P2State.reset()` (which the click
/// precedes). Standalone + self-locked (the `AudioCushionTelemetry` idiom), read
/// by the exporter without touching the snapshot structs. First writer wins per
/// edge; `resetForNewSession` clears it.
final class ConnectTimingTelemetry: @unchecked Sendable {
    static let shared = ConnectTimingTelemetry()

    private let lock = os_unfair_lock_t.allocate(capacity: 1)
    /// Wall-clock reference of the user's click; 0 = no click anchored.
    private var clickReference: Double = 0
    /// Wall-clock reference of connect-start (for the launch-path leg); 0 = unset.
    private var connectStartReference: Double = 0
    private var clickToFirstFrameMsValue: Double = 0
    private var launchPathMsValue: Double = 0
    init() { lock.initialize(to: os_unfair_lock_s()) }
    deinit { lock.deallocate() }

    /// Anchor the click instant. Called from `MoonlightManager.stream()` at the
    /// user's launch click - before the connect Task spins up. First write wins
    /// per session (reset clears it).
    func anchorClick() {
        let now = Date().timeIntervalSinceReferenceDate
        os_unfair_lock_lock(lock)
        if clickReference == 0 { clickReference = now }
        os_unfair_lock_unlock(lock)
    }
    /// Mark connect-start to isolate the launch cost (click → connectStart).
    /// First write wins; no-op if the click was never anchored.
    func markConnectStart() {
        let now = Date().timeIntervalSinceReferenceDate
        os_unfair_lock_lock(lock)
        if clickReference > 0, connectStartReference == 0, now >= clickReference {
            connectStartReference = now
            launchPathMsValue = (now - clickReference) * 1000.0
        }
        os_unfair_lock_unlock(lock)
    }
    /// Resolve click → first decoded frame. Called at the `.firstFrame` edge;
    /// first write wins, no-op without a click anchor.
    func markFirstFrame() {
        let now = Date().timeIntervalSinceReferenceDate
        os_unfair_lock_lock(lock)
        if clickReference > 0, clickToFirstFrameMsValue == 0, now >= clickReference {
            clickToFirstFrameMsValue = (now - clickReference) * 1000.0
        }
        os_unfair_lock_unlock(lock)
    }
    /// Click → first decoded frame (ms), or nil if not yet resolved.
    var clickToFirstFrameMs: Double? {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        return clickToFirstFrameMsValue != 0 ? clickToFirstFrameMsValue : nil
    }
    /// Launch path: click → connect-start (ms), or nil if not yet measured.
    var launchPathMs: Double? {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        return launchPathMsValue != 0 ? launchPathMsValue : nil
    }
    func resetForNewSession() {
        os_unfair_lock_lock(lock)
        clickReference = 0; connectStartReference = 0
        clickToFirstFrameMsValue = 0; launchPathMsValue = 0
        os_unfair_lock_unlock(lock)
    }
}

// MARK: - Handshake breakdown snapshot

/// One session's CONNECT-HANDSHAKE breakdown: the per-stage durations (ms) of the
/// connect sequence, all measured connect-relative from the SAME monotonic anchor
/// the exporter uses, so the stages line up on the timeline. Each leg is optional
/// - a stage that never fired (a path that aborts early) is simply absent rather
/// than guessed. Assembled on the exporter queue from the always-live
/// `HandshakeTimeline`; never the hot path.
struct HandshakeBreakdown: Sendable {
    /// RTSP/SDP handshake duration (name-resolution start → RTSP-handshake done).
    var rtspMs: Double?
    /// Pairing/auth leg (control-crypto + control-V2 negotiation) - the gap from
    /// RTSP-done to ENet-connect start, which is where the per-session AES/auth
    /// material is set up before the control socket opens.
    var pairingMs: Double?
    /// ENet control-channel connect (ENET_CONNECT → START_A → START_B ACKed).
    var enetConnectMs: Double?
    /// Time from connection-established to the FIRST decoded video frame - the
    /// "black screen until pixels" leg the user actually feels.
    var firstFrameMs: Double?
    /// Total: connect start → first decoded video frame (the whole cold open).
    var totalMs: Double?
    /// TRUE click-to-pixels: the user's launch click → first decoded frame, which
    /// includes the serverinfo + launch + busy-poll legs `totalMs` excludes (it
    /// anchors at connect-start). From `ConnectTimingTelemetry`.
    var clickToFirstFrameMs: Double?
    /// Launch path: click → connect-start, isolating the pre-connect launch cost.
    var launchPathMs: Double?
    /// True once the first decoded frame landed (so the exporter emits the
    /// one-shot breakdown exactly once, not every tick).
    var complete: Bool = false
}

// MARK: - IDR/RFI round-trip snapshot

/// IDR/RFI ROUND-TRIP telemetry for one tick: the count of requests we've sent +
/// the count that have been matched to an arriving IDR/recovery frame, plus the
/// most-recent measured round-trip (ms). The full distribution rides the latency
/// histogram (`idrRoundTrip` in `LatencyHistograms`); this carries the live gauge
/// + counts for a glanceable scrape. Assembled on the exporter queue.
struct IdrRoundTripSnapshot: Sendable {
    /// EXPLICIT IDR requests sent that started a round-trip measurement
    /// (monotonic; RFIs ride rfi_total and don't arm).
    var requestsTotal: UInt64 = 0
    /// Requests that were matched to an arriving IDR/recovery frame (monotonic).
    var matchedTotal: UInt64 = 0
    /// Most recent measured request→IDR round-trip (ms), nil if none yet.
    var lastRoundTripMs: Double?
}

// MARK: - TelemetryCounters: P2 session-lifecycle state

extension TelemetryCounters {

    // The concrete stored state for these signals lives on `TelemetryCounters`
    // (the always-live singleton) via the `P2State` holder below, reached through
    // the `p2` accessor. Keeping the storage in one lock-guarded holder (rather
    // than a dozen more stored properties on the main class) keeps both files
    // focused and the locking obvious.

    /// One cheap monotonic-clock read (`DispatchTime.now().uptimeNanoseconds`).
    /// Shared by the P2 lifecycle/recovery sites so they all stamp on the same
    /// monotonic clock the latency tracker uses. A single function so the clock
    /// choice is one edit.
    static func monotonicNowNanos() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    /// All P2 session-lifecycle state behind one lock. `@unchecked Sendable`: the
    /// single `os_unfair_lock` guards every field; last-writer-wins is correct for
    /// 1Hz-sampled gauges, and the rare lifecycle/recovery writers never contend.
    final class P2State: @unchecked Sendable {
        private let lock = os_unfair_lock_t.allocate(capacity: 1)
        init() { lock.initialize(to: os_unfair_lock_s()) }
        deinit { lock.deallocate() }

        // ---- Handshake timeline (monotonic stage instants, ns) ----
        private var connectStartNanos: UInt64 = 0
        private var rtspStartNanos: UInt64 = 0
        private var rtspDoneNanos: UInt64 = 0
        private var enetStartNanos: UInt64 = 0
        private var establishedNanos: UInt64 = 0
        private var firstFrameNanos: UInt64 = 0

        // ---- Disconnect reason (latched at the terminate edge) ----
        private var disconnectReasonValue: DisconnectReason = .none
        /// One-shot guard: the process-global per-reason counter is bumped at
        /// most once per session, at genuine teardown - not at the per-terminate
        /// latch (a recoverable blip latches a reason but must not be counted).
        private var globalReasonCounted = false

        // ---- IDR/RFI round-trip ----
        /// Monotonic instant of the most recent IDR/RFI request we sent that is
        /// still awaiting its matching IDR arrival, or 0 if none is outstanding.
        /// Single outstanding request is sufficient: requests coalesce to ≤1 per
        /// loss event on the send side, so a newer request simply replaces the
        /// timer (we measure to the next IDR either way).
        private var idrRequestPendingNanos: UInt64 = 0
        private var idrLastRoundTripMs: Double = 0

        func anchorConnectStart(_ now: UInt64) {
            os_unfair_lock_lock(lock)
            if connectStartNanos == 0 { connectStartNanos = now }
            os_unfair_lock_unlock(lock)
        }
        /// The TRUE session/connect-start instant (monotonic ns), or 0 if not yet
        /// anchored. This is the session-lifecycle anchor stamped at the connect
        /// edge (and preserved across the exporter's own `resetForNewSession`), so
        /// per-session cold-start metrics (e.g. time-to-first-audio) measure from
        /// the real session start rather than a later, resettable epoch.
        var connectStart: UInt64 {
            os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
            return connectStartNanos
        }
        func markRtspStart(_ now: UInt64) {
            os_unfair_lock_lock(lock); if rtspStartNanos == 0 { rtspStartNanos = now }; os_unfair_lock_unlock(lock)
        }
        func markRtspDone(_ now: UInt64) {
            os_unfair_lock_lock(lock); if rtspDoneNanos == 0 { rtspDoneNanos = now }; os_unfair_lock_unlock(lock)
        }
        func markEnetStart(_ now: UInt64) {
            os_unfair_lock_lock(lock); if enetStartNanos == 0 { enetStartNanos = now }; os_unfair_lock_unlock(lock)
        }
        /// Anchor the handshake's `establishedNanos` leg (first edge only). The
        /// reconnect signal is NOT derived here - reconnectInPlace re-runs p2.reset()
        /// before the fresh edge, so it's counted at the recovery site instead.
        func markEstablished() {
            os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
            if establishedNanos == 0 { establishedNanos = TelemetryCounters.monotonicNowNanos() }
        }
        func markFirstFrame(_ now: UInt64) {
            os_unfair_lock_lock(lock); if firstFrameNanos == 0 { firstFrameNanos = now }; os_unfair_lock_unlock(lock)
        }

        /// Assemble the handshake breakdown from whatever stages have fired. Each
        /// leg is emitted only when both its endpoints exist (so an aborted-early
        /// connect omits the legs it never reached rather than reporting 0).
        func handshakeBreakdown() -> HandshakeBreakdown {
            os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
            var out = HandshakeBreakdown()
            out.rtspMs = msBetween(rtspStartNanos, rtspDoneNanos)
            out.pairingMs = msBetween(rtspDoneNanos, enetStartNanos)
            out.enetConnectMs = msBetween(enetStartNanos, establishedNanos)
            out.firstFrameMs = msBetween(establishedNanos, firstFrameNanos)
            out.totalMs = msBetween(connectStartNanos, firstFrameNanos)
            // TRUE click-to-pixels + the isolated launch leg, from the wall-clock
            // click latch (anchored before connect-start, so it sees the legs
            // totalMs can't). Self-locked; read here off the P2 lock.
            out.clickToFirstFrameMs = ConnectTimingTelemetry.shared.clickToFirstFrameMs
            out.launchPathMs = ConnectTimingTelemetry.shared.launchPathMs
            out.complete = firstFrameNanos != 0
            return out
        }

        /// Latch the per-session disconnect-reason ordinal (the FIRST concrete
        /// reason wins). Does NOT touch the global counter - a recoverable blip
        /// latches here but is silently recovered, so counting it would inflate
        /// the "why sessions ended" tally. Returns true iff this call won.
        @discardableResult
        func setDisconnectReason(_ reason: DisconnectReason) -> Bool {
            os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
            guard disconnectReasonValue == .none, reason != .none else { return false }
            disconnectReasonValue = reason
            return true
        }

        /// At GENUINE teardown, return the latched reason for the process-global
        /// counter exactly once per session (nil if no reason, or already counted).
        func countGlobalReasonOnce() -> DisconnectReason? {
            os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
            guard !globalReasonCounted, disconnectReasonValue != .none else { return nil }
            globalReasonCounted = true
            return disconnectReasonValue
        }
        var disconnectReason: DisconnectReason {
            os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
            return disconnectReasonValue
        }

        /// Stamp the instant an IDR/RFI request went out (replacing any pending).
        func stampIdrRequest(_ now: UInt64) {
            os_unfair_lock_lock(lock); idrRequestPendingNanos = now; os_unfair_lock_unlock(lock)
        }
        /// Resolve the pending IDR request against an arriving IDR/recovery frame.
        /// Returns the round-trip (ms) if a request was outstanding, else nil (an
        /// unsolicited IDR - the host's own keyframe cadence - isn't a round-trip).
        func resolveIdrArrival(_ now: UInt64) -> Double? {
            os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
            let pending = idrRequestPendingNanos
            guard pending != 0, now >= pending else { return nil }
            idrRequestPendingNanos = 0
            let ms = Double(now &- pending) / 1_000_000.0
            idrLastRoundTripMs = ms
            return ms
        }
        var lastIdrRoundTripMs: Double? {
            os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
            return idrLastRoundTripMs != 0 ? idrLastRoundTripMs : nil
        }

        func reset() {
            os_unfair_lock_lock(lock)
            connectStartNanos = 0; rtspStartNanos = 0; rtspDoneNanos = 0
            enetStartNanos = 0; establishedNanos = 0; firstFrameNanos = 0
            disconnectReasonValue = .none; globalReasonCounted = false
            idrRequestPendingNanos = 0; idrLastRoundTripMs = 0
            os_unfair_lock_unlock(lock)
        }

        /// Delta (ms) between two monotonic ns stamps, or nil if either is unset
        /// (0) or the delta is negative. Same discipline as the latency tracker.
        private func msBetween(_ start: UInt64, _ end: UInt64) -> Double? {
            guard start != 0, end != 0, end >= start else { return nil }
            return Double(end &- start) / 1_000_000.0
        }
    }
}
