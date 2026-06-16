//
//  RtpAudioReceiver+StartupGate.swift
//
//  The backlog-aware startup gate's state machine - measure the first
//  window's arrival pacing, drain only a proven backlog flush to the live
//  edge, latch the verdict one-shot. Replaces moonlight-common-c's fixed
//  500ms start drop; the full WHY lives on the gate state docs in the core
//  file. Split out of RtpAudioReceiver.swift - pure move, the FramePacer
//  split idiom - to keep that file under the length limit; the
//  StartupPacing enum and the gate's stored state stay declared on the
//  receiver, recvQueue-confined as before.
//

import Foundation

extension RtpAudioReceiver {

    /// Classify this datagram's place in the startup flow; returns true iff its
    /// decode output is STALE (the hand-off discards it). Called only until the
    /// verdict latches (`.decided` short-circuits at the call site), so the
    /// steady-state datagram path never enters here.
    ///
    /// MEASURING: count data packets, decode everything. At the decision packet
    /// (one window of audio-ms after the first), a single clock read settles
    /// it: arrived-audio ÷ elapsed-wall ≥ `startupBurstRateFloor` can only be a
    /// backlog flush (see the floor's docs), so flip to DRAINING starting with
    /// this packet. Below the floor, latch PACED - the proven-normal Sunshine
    /// start - having withheld nothing.
    ///
    /// DRAINING: drop until the live edge, detected as the backlog-ahead
    /// estimate (arrived-audio-ms − elapsed-wall-ms) failing to grow by at
    /// least half a packet duration - a flush grows it by ~one packet per
    /// packet (audio-ms arrive in ~zero wall time), live pacing by ~0. Any
    /// mid-drain delivery pause also fails the growth test and ends the drain
    /// EARLY - deliberately the safe direction: under-dropping leaves extra
    /// cushion for the decoder's rate-limited trim to bleed down, while
    /// over-dropping would eat live audio (the exact cost this gate removes).
    func updateStartupPacing(isData: Bool) -> Bool {
        switch startupPacing {
        case .decided:
            return false
        case .measuring:
            // FEC datagrams carry parity, not audio-ms - never measured (see
            // the field docs), and anything they recover decodes like the rest
            // of the measuring window.
            guard isData else { return false }
            if startupFirstDataNanos == 0 {
                startupFirstDataNanos = DispatchTime.now().uptimeNanoseconds
                return false
            }
            startupDataPackets += 1
            guard startupDataPackets >= startupDecisionPackets else { return false }
            let elapsedMs = elapsedSinceFirstDataMs()
            let arrivedMs = arrivedAudioMs()
            guard arrivedMs >= elapsedMs * Self.startupBurstRateFloor else {
                latchStartupVerdict(burst: false, arrivedMs: arrivedMs, elapsedMs: elapsedMs)
                return false
            }
            // Backlog flush: outputs are stale from here to the live edge. The
            // window already decoded stays scheduled - that's the cushion the
            // listener rides while the drain catches us up.
            startupPacing = .draining
            startupPrevAheadMs = arrivedMs - elapsedMs
            return true
        case .draining:
            // FEC recoveries during the drain sit behind the live edge by
            // construction (parity only rebuilds packets already passed), so
            // they share the stale verdict.
            guard isData else { return true }
            startupDataPackets += 1
            let elapsedMs = elapsedSinceFirstDataMs()
            let aheadMs = arrivedAudioMs() - elapsedMs
            if aheadMs >= startupPrevAheadMs + Double(audioPacketDuration) / 2 {
                startupPrevAheadMs = aheadMs
                return true
            }
            // The live edge: arrivals fell back to ~1x. THIS packet is fresh -
            // latch the verdict and let it decode.
            latchStartupVerdict(burst: true, arrivedMs: arrivedAudioMs(), elapsedMs: elapsedMs)
            return false
        }
    }

    /// Quiet-socket resolution for a pending verdict: 100ms of recv silence
    /// (the SO_RCVTIMEO poll) proves no backlog remains queued behind us - a
    /// kernel/host flush delivers back-to-back and cannot pause. Whatever
    /// arrives NEXT is delayed live audio, so a still-measuring window latches
    /// PACED (it withheld nothing) and an in-flight drain ends where it
    /// stands. Before the first data packet this is a no-op - there is nothing
    /// to measure yet, and the poll fires every 100ms while the host's audio
    /// pipeline spins up.
    func resolveStartupPacingOnIdle() {
        guard startupPacing != .decided, startupFirstDataNanos != 0 else { return }
        latchStartupVerdict(burst: startupPacing == .draining,
                            arrivedMs: arrivedAudioMs(),
                            elapsedMs: elapsedSinceFirstDataMs(),
                            idleResolved: true)
    }

    /// One-shot verdict latch: flip the gate to its steady (single-compare)
    /// state, log the decision ONCE in the METRIC line style - so the startup
    /// story reads as one block next to time-to-first-packet - and emit the
    /// deferred `audio_ttf` event row, deferred to exactly this moment so it
    /// can carry the verdict alongside both TTF spans. The logged rate spans
    /// everything measured up to the latch (window + any drain/idle tail):
    /// ~1x reads paced, a real flush still reads well above the floor.
    private func latchStartupVerdict(burst: Bool, arrivedMs: Double,
                                     elapsedMs: Double, idleResolved: Bool = false) {
        startupPacing = .decided
        startupVerdictBurst = burst
        let droppedMs = startupDroppedPackets * audioPacketDuration
        let rate = arrivedMs / max(elapsedMs, 0.001)
        Diag.notice("NativeAudio METRIC startup-pacing=\(burst ? "burst" : "paced") "
            + String(format: "rate=%.1fx", rate)
            + " (\(String(format: "%.0f", arrivedMs))ms audio in "
            + "\(String(format: "%.0f", elapsedMs))ms)"
            + " dropped=\(droppedMs)ms"
            + (idleResolved ? " resolved-on-idle" : "")
            + (burst ? " - backlog flushed; kept the decoded window as the cushion"
                     : " - live flow from the first packet; nothing withheld"), Self.cat)
        emitAudioTtfEvent()
    }

    /// Audio-ms arrived since the pacing zero (the first data packet, itself
    /// uncounted - `startupDataPackets` counts the packets AFTER it, so this
    /// is exactly the audio that arrived across `elapsedSinceFirstDataMs()`).
    private func arrivedAudioMs() -> Double {
        Double(startupDataPackets * audioPacketDuration)
    }

    /// One monotonic clock read, in ms since the first data packet.
    private func elapsedSinceFirstDataMs() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds &- startupFirstDataNanos) / 1_000_000
    }
}
