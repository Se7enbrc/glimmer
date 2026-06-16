//
//  MoonlightManager+SessionReceipt.swift
//
//  The end-of-stream session receipt: a small per-(host, mode) record stashed
//  in UserDefaults when a session ends. Two readers: the launcher's "Stream
//  ended" toast (the quiet "2h 12m · 12 ms median" line) and the Settings
//  track's quality-guidance copy. Harness-independent by construction — every
//  number rides an ALWAYS-LIVE surface (the ENet RTT EWMA via
//  `StreamingBackend.estimatedRtt`, `StatsCollector`'s session byte total),
//  never the gate-on telemetry rig, so removing the telemetry exporter
//  cannot take this feature with it.
//
//  ── SHARED KEY CONTRACT (the Settings track reads this — keep in sync) ──
//
//    Key:   "glimmer.lastSession.<hostId>.<width>x<height>@<hz>"
//           e.g. "glimmer.lastSession.0123ABCD.2560x1440@120"
//    Value: JSON blob (JSONEncoder, dates encoded as secondsSince1970):
//           {
//             "durationSeconds": 7942.1,   // live edge → teardown wall time
//             "medianRttMs": 12.4,         // ENet RTT EWMA at stream end
//             "avgGoodputMbps": 41.7,      // video bytes · 8 / duration
//             "width": 2560, "height": 1440, "refreshHz": 120,
//             "date": 1765400000           // when the session ENDED
//           }
//           `medianRttMs` / `avgGoodputMbps` are absent when unmeasured.
//
//  Only sessions ≥ 5 minutes are stashed: sub-5-minute sessions are config
//  experiments and failed launches, and would poison the guidance numbers.
//
//  Lifecycle (three writers, one rendezvous):
//    1. `markStreamStart`  — MoonlightManager.stream(), arms the latch with
//                            the session's identity (host + requested mode).
//    2. `markSessionLive`  — first .connectionEstablished / .firstFrame edge,
//                            stamps the wall clock the duration counts from.
//    3. `captureStreamEnd` — the ONE engine-side hook (StreamSession.stop(),
//                            before the backend tears down), grabs RTT+bytes.
//    4. `finalizeSession`  — MoonlightManager's teardown cleanup, builds the
//                            receipt, gates ≥ 5 min, writes the blob.
//

import Foundation
import os

// MARK: - Receipt model

/// One finished session's footprint. Codable shape IS the key contract above.
struct SessionReceipt: Codable, Equatable {
    var durationSeconds: TimeInterval
    /// The ENet control channel's RTT EWMA read at stream end — a smoothed
    /// central estimate ("median-grade"), deliberately sourced from the
    /// always-live channel and never the gated latency rig.
    var medianRttMs: Double?
    /// Session-average video goodput: total received video bytes · 8 over the
    /// live wall time. Includes idle/menu time — that's what "average" means.
    var avgGoodputMbps: Double?
    var width: Int
    var height: Int
    var refreshHz: Int
    /// When the session ENDED (the stash moment).
    var date: Date

    /// The toast's quiet line: "2h 12m · 12 ms median" (duration only when
    /// RTT was never measured).
    var summaryLine: String {
        var parts = [Self.durationLabel(durationSeconds)]
        if let rtt = medianRttMs {
            parts.append("\(Int(rtt.rounded())) ms median")
        }
        return parts.joined(separator: " · ")
    }

    /// "2h 12m" / "38m". Receipts only exist for ≥ 5 min sessions, so a
    /// seconds-level unit would be false precision.
    private static func durationLabel(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes)m"
    }
}

// MARK: - Store

/// UserDefaults-backed stash + the cross-actor rendezvous for the numbers
/// captured at the teardown edge. All statics are NSLock-guarded because the
/// writers span the main actor (start/live/finalize) and the StreamSession
/// actor (the end-of-stream capture) — same latch discipline as
/// `StreamRouteProbe.latchHost`.
enum SessionReceiptStore {

    /// Sessions shorter than this are never stashed (see the file header).
    static let minimumSessionSeconds: TimeInterval = 5 * 60

    /// Identity + clocks for the session currently in flight (nil between
    /// sessions). `liveAt` stays nil until the live edge so a connect that
    /// never establishes can't produce a receipt.
    private struct PendingSession {
        var hostId: String
        var width: Int
        var height: Int
        var refreshHz: Int
        var liveAt: Date?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var pending: PendingSession?
    nonisolated(unsafe) private static var endRttMs: Double?
    nonisolated(unsafe) private static var endVideoBytes: UInt64?
    nonisolated(unsafe) private static var endedAt: Date?

    /// The exact persisted-key contract — single source for both tracks.
    static func key(hostId: String, width: Int, height: Int, refreshHz: Int) -> String {
        "glimmer.lastSession.\(hostId).\(width)x\(height)@\(refreshHz)"
    }

    /// Arm the latch for a new session attempt. Clears any leftovers from a
    /// previous attempt (e.g. a connect that threw before its teardown hook).
    static func markStreamStart(hostId: String, width: Int, height: Int, refreshHz: Int) {
        lock.lock()
        pending = PendingSession(hostId: hostId, width: width, height: height, refreshHz: refreshHz)
        endRttMs = nil
        endVideoBytes = nil
        endedAt = nil
        lock.unlock()
    }

    /// Stamp the wall clock the duration counts from. Latched ONCE per
    /// session — `.connectionEstablished` and the `.firstFrame` promote path
    /// both call this, and reconnect-quality events must not restart it.
    static func markSessionLive() {
        lock.lock()
        if pending != nil, pending?.liveAt == nil {
            pending?.liveAt = Date()
        }
        lock.unlock()
    }

    /// Capture the always-live end-of-session numbers. Called from
    /// `StreamSession.stop()` (the one engine-side hook) BEFORE the backend
    /// tears down — `estimatedRtt()` dies with the connection, and the
    /// collector resets on the next session. `receivedBytes` has no accessor
    /// of its own, so we take the same unfair lock the collector's own
    /// accessors take — a one-shot read at the teardown edge, never hot path.
    static func captureStreamEnd(rttMs: Double?, collector: StatsCollector?) {
        var videoBytes: UInt64?
        if let collector {
            os_unfair_lock_lock(&collector.lock)
            videoBytes = collector.receivedBytes
            os_unfair_lock_unlock(&collector.lock)
        }
        lock.lock()
        endRttMs = rttMs
        endVideoBytes = videoBytes
        endedAt = Date()
        lock.unlock()
    }

    /// Build + stash the receipt for the session that just ended. Returns nil
    /// (and stashes nothing) when the session never went live or ran under
    /// the 5-minute threshold. Consumes the latch either way, so a receipt
    /// can never be double-counted or leak into the next session.
    static func finalizeSession() -> SessionReceipt? {
        lock.lock()
        let session = pending
        let rtt = endRttMs
        let bytes = endVideoBytes
        let ended = endedAt ?? Date()
        pending = nil
        endRttMs = nil
        endVideoBytes = nil
        endedAt = nil
        lock.unlock()

        guard let session, let liveAt = session.liveAt else { return nil }
        let duration = ended.timeIntervalSince(liveAt)
        guard duration >= minimumSessionSeconds else { return nil }

        let receipt = SessionReceipt(
            durationSeconds: duration,
            medianRttMs: rtt,
            avgGoodputMbps: bytes.map { Double($0) * 8.0 / 1_000_000.0 / duration },
            width: session.width,
            height: session.height,
            refreshHz: session.refreshHz,
            date: ended)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        if let data = try? encoder.encode(receipt) {
            UserDefaults.standard.set(data, forKey: key(
                hostId: session.hostId, width: session.width,
                height: session.height, refreshHz: session.refreshHz))
        }
        return receipt
    }

    /// Read half of the contract (the guidance copy in Settings rides this).
    static func load(hostId: String, width: Int, height: Int, refreshHz: Int) -> SessionReceipt? {
        let storageKey = key(hostId: hostId, width: width, height: height, refreshHz: refreshHz)
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(SessionReceipt.self, from: data)
    }
}
