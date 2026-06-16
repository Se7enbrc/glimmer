//
//  RtpAudioReceiver+Ping.swift
//
//  The audio keepalive ping: a dedicated OS thread bursting the first ~2s at
//  80ms then settling to the steady cadence (Sunshine times the whole session
//  out if the keepalive stops), with streak-edge sendto honesty logging —
//  plus the AtomicUInt64 cell the ping→recv time-to-first-packet metric
//  rides. Split out of RtpAudioReceiver.swift — pure move, the FramePacer
//  split idiom — to keep that file under the length limit; the
//  cadence dials (burst/steady) and the ping counters stay declared on the
//  receiver.
//

import Foundation
import Darwin

extension RtpAudioReceiver {

    /// Dedicated OS thread (NOT the cooperative pool) — Sunshine times out the whole
    /// session if the audio keepalive ping stops. Mirrors moonlight's
    /// AudioPingThreadProc dedicated pthread (AudioStream.c:38-64), but BURSTS the
    /// initial pings so the host receives one (and starts aiming audio) within a
    /// few tens of ms of the socket opening, then settles to the CONDITIONAL
    /// steady keepalive (EnvSignalController.steadyPingInterval — 75ms fast /
    /// 500ms relaxed; WHY/VERDICT/COST on UdpPinger's dial). The burst is the
    /// latency fix and stays UNCONDITIONAL by design (its job is first-ping
    /// latency, not the doze hold); the steady tail wakes at the fast quantum
    /// (steadyIntervalSec — the pre-conditional wake rate, no new thread cost)
    /// and gates each SEND on the live interval, so a cadence flip takes
    /// effect within one quantum.
    func startPingLoop() {
        EnvSignalController.shared.noteAudioPingLoopStart()
        let burstUntil = Date().addingTimeInterval(Self.burstDurationSec)
        let thread = Thread { [weak self] in
            // 0 = "never pinged" — the first post-burst wake always sends.
            var lastPingNanos: UInt64 = 0
            while let self, !self.interrupted.isSet {
                // Burst for the first ~2s, then settle to the steady keepalive.
                if Date() < burstUntil {
                    self.sendPing()
                    lastPingNanos = DispatchTime.now().uptimeNanoseconds
                    Thread.sleep(forTimeInterval: Self.burstIntervalSec)
                    continue
                }
                let interval = EnvSignalController.shared.steadyPingInterval()
                let now = DispatchTime.now().uptimeNanoseconds
                if now &- lastPingNanos >= EnvSignalController.dueNanos(for: interval) {
                    self.sendPing()
                    lastPingNanos = now
                }
                Thread.sleep(forTimeInterval: Self.steadyIntervalSec)
            }
        }
        thread.name = "Glimmer.audioPing"
        thread.qualityOfService = .userInitiated
        pingThread = thread
        thread.start()
    }

    private func sendPing() {
        guard fd >= 0 else { return }
        let datagram: [UInt8]
        if !pingPayload.isEmpty {
            pingCount &+= 1
            var out = pingPayload                 // 16 bytes
            withUnsafeBytes(of: pingCount.bigEndian) { out.append(contentsOf: $0) }  // 4 bytes BE
            datagram = out
        } else {
            // Legacy GFE 4-byte "PING". Still count it for the metric.
            pingCount &+= 1
            datagram = [0x50, 0x49, 0x4E, 0x47]
        }
        let sent = datagram.withUnsafeBytes { raw in
            withUnsafePointer(to: &destAddr) { sp in
                sp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sap in
                    sendto(fd, raw.baseAddress, raw.count, 0, sap, destAddrLen)
                }
            }
        }
        // sendto HONESTY: a discarded result made a client-side transmit failure
        // (ENOBUFS, route flap, WMM/VO uplink rejection) indistinguishable from
        // host-side audio delay — the one client-side gap in the TTF attribution
        // story. Log on the STREAK EDGES only (first failure + recovery), never
        // per packet, so a dead route can't flood the diagnostic ring at the
        // burst cadence. UDP sendto is all-or-error, so <0 is the failure test.
        if sent < 0 {
            let err = errno
            pingSendFailureStreak += 1
            if pingSendFailureStreak == 1 {
                Diag.warn("NativeAudio ping sendto failed errno \(err) — the host may not be "
                    + "receiving our audio keepalive (will keep trying)", Self.cat)
            }
        } else if pingSendFailureStreak > 0 {
            Diag.notice("NativeAudio ping sendto recovered after \(pingSendFailureStreak) "
                + "failed send\(pingSendFailureStreak == 1 ? "" : "s")", Self.cat)
            pingSendFailureStreak = 0
        }
        // Publish the metric counters for the recv thread (time-to-first-packet).
        pingsSent.store(UInt64(pingCount))
        // pings_sent (the keepalive cadence judge): counts datagrams handed
        // to sendto — the counter whose absence made the 75ms experiment
        // unjudgeable from data. Always-live integer add at ≤13.3Hz.
        EnvSignalController.shared.audioPingsSentTotal.increment()
        if pingCount == 1 {
            pingStartTimeUs.store(UInt64(DispatchTime.now().uptimeNanoseconds / 1000))
            Diag.notice("NativeAudio first audio ping sent → \(host):\(audioPort) "
                + "(\(pingPayload.isEmpty ? "legacy" : "payload") seq=\(pingCount))", Self.cat)
        }
    }
}

/// A tiny lock-guarded UInt64 cell for the few values that cross the audio
/// ping↔recv thread boundary (the time-to-first-packet metric). Mirrors
/// ManagedAtomicFlag's NSLock style — sufficient for monotonic, low-rate writes.
final class AtomicUInt64: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    func store(_ newValue: UInt64) { lock.lock(); value = newValue; lock.unlock() }
    func load() -> UInt64 { lock.lock(); defer { lock.unlock() }; return value }
}
