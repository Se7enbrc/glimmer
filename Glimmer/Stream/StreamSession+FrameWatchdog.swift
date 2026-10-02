//
//  StreamSession+FrameWatchdog.swift
//
//  The frame-decode watchdog ("did the user see a frame?") and the stall handlers it drives: the
//  decode-only diagnostic, the backed-off keyframe nudge, the hold-or-tear-down timeout, and the one
//  reconnect that rebuilds a decoder fed packets it never decodes. +Watchdog covers the present path.
//

import Foundation
import AppKit
import os

/// Keyframe nudges for one decode stall: at 2 s, then 4, 8, 16 and every 16 s after. A paused encoder
/// answers the first; repeats only push more keyframes into whatever is already failing.
struct DecodeStallNudge: Equatable {
    static let maxIntervalSeconds: Double = 16
    private(set) var nextAt = StreamSession.decodeStallRecoveryThreshold
    private var interval = StreamSession.decodeStallRecoveryThreshold

    /// True once per schedule point as `decodeIdle` (seconds without a decoded frame) crosses it.
    mutating func due(at decodeIdle: Double) -> Bool {
        guard decodeIdle >= nextAt else { return false }
        nextAt += interval
        interval = min(interval * 2, Self.maxIntervalSeconds)
        return true
    }
}

extension StreamSession {

    /// moonlight-common-c's ML_ERROR_NO_VIDEO_TRAFFIC: no video frame ever
    /// arrived, almost always a firewall on UDP 47998 or a VPN's MTU.
    static let noVideoTrafficTerminationCode: Int32 = -100
    /// ML_ERROR_NO_VIDEO_FRAME: video arrived, but not one frame decoded.
    static let noVideoFrameTerminationCode: Int32 = -101
    /// Packets arriving while nothing decodes for this long, on a live control link, earns one reconnect
    /// in place: it rebuilds the receiver and the decode session, which the hold alone never would.
    static let decodeOnlyReconnectSeconds: Double = 30

    /// The terminate code a watchdog teardown reports. A bring-up that never
    /// showed a frame names why, so the user gets the right fix; a stall
    /// after video flowed is the dead-peer loss (-1).
    static func watchdogTerminationCode(
        neverDecodedFirstFrame: Bool, receiveIdleSeconds: Double
    ) -> Int32 {
        guard neverDecodedFirstFrame else { return deadPeerTerminationCode }
        return receiveIdleSeconds.isFinite ? noVideoFrameTerminationCode : noVideoTrafficTerminationCode
    }

    /// Decode silence for this connection. A reconnect inherits the old connection's decoded-frame
    /// clock, so it is floored at this connection's arm; a gate lift since the arm also restarts it.
    static func watchdogDecodeIdle(sinceDecoded: Double, sinceGateLift: Double, sinceArm: Double) -> Double {
        let gateLift = sinceGateLift <= sinceArm ? sinceGateLift : .infinity
        let decoded = sinceDecoded.isFinite ? min(sinceDecoded, sinceArm) : .infinity
        return min(decoded, gateLift)
    }

    /// Install the frame-arrival watchdog: 1 Hz on the main run loop, gated on decoded frames rather
    /// than bytes, so video the Mac can't decode ends in an error instead of a black screen.
    func startFrameWatchdog() async {
        let dec = videoDecoder
        await MainActor.run {
            self.frameWatchdogTimer?.invalidate()
            self.frameWatchdogArmedAt = CACurrentMediaTime()
            let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self, weak dec] _ in
                guard let self, let dec else { return }
                self.frameWatchdogTick(decoder: dec)
            }
            timer.tolerance = 0.1
            self.frameWatchdogTimer = timer
        }
    }

    /// One watchdog tick, on the main thread. A gated decoder (hidden window) is healthy by design and
    /// trips nothing; stopConnection clears the gate, so it can never shield a dead session from teardown.
    nonisolated func frameWatchdogTick(decoder dec: VideoDecoder) {
        if dec.decodeGated { return }
        let sinceArm = CACurrentMediaTime() - frameWatchdogArmedAt
        let sinceDecoded = dec.secondsSinceLastDecodedFrame()
        let decodeIdle = Self.watchdogDecodeIdle(
            sinceDecoded: sinceDecoded, sinceGateLift: dec.secondsSinceDecodeGateLifted(), sinceArm: sinceArm)
        let receiveIdle = dec.secondsSinceLastReceivedFrame()
        guard decodeIdle.isFinite else {
            // Nothing decoded yet: moonlight's FIRST_FRAME_TIMEOUT_SEC runs from the arm, with no
            // ENet-alive hold (a broken bring-up, not a paused desktop).
            if frameWatchdogArmedAt > 0, sinceArm > Self.frameWatchdogTimeout {
                Task { [weak self] in
                    await self?.handleWatchdogTimeout(
                        decodeIdleSeconds: sinceArm, receiveIdleSeconds: receiveIdle, neverDecodedFirstFrame: true)
                }
            }
            return
        }
        if decodeIdle > Self.decodeOnlyStallThreshold, receiveIdle < Self.decodeOnlyStallThreshold {
            Task { [weak self] in await self?.handleDecodeOnlyStall(decodeIdle: decodeIdle, receiveIdle: receiveIdle) }
        } else if sinceDecoded < Self.decodeOnlyStallThreshold {
            Task { [weak self] in await self?.clearDecodeOnlyStallLatch() }
        }
        if decodeIdle > Self.decodeStallRecoveryThreshold {
            Task { [weak self] in
                await self?.attemptDecodeStallRecovery(decodeIdle: decodeIdle, receiveIdle: receiveIdle)
            }
        }
        // Past the keyframe nudges: bits arriving, none decoding, long enough that the rate is the only
        // thing left to change on a remote path (see +Downshift).
        if decodeIdle >= BitrateDownshiftController.stallSecondsBeforeDownshift {
            Task { [weak self] in
                await self?.considerBitrateDownshift(decodeIdle: decodeIdle, receiveIdle: receiveIdle)
            }
        }
        guard decodeIdle > Self.frameWatchdogTimeout else { return }
        Task { [weak self] in
            await self?.handleWatchdogTimeout(decodeIdleSeconds: decodeIdle, receiveIdleSeconds: receiveIdle)
        }
    }

    /// Log the "bytes received but no decoded output" diagnostic once per
    /// stall episode. Latched so we don't spam the log once a second while
    /// the host continues to send unparseable data.
    fileprivate func handleDecodeOnlyStall(
        decodeIdle: Double, receiveIdle: Double
    ) async {
        guard isStreaming, !stopInProgress, !isReconnecting else { return }
        if didLogDecodeOnlyStall { return }
        didLogDecodeOnlyStall = true
        stallStartPackets = (TelemetryCounters.shared.videoPacketsTotal.value, ProcessInfo.processInfo.systemUptime)
        // .public privacy so this lands in `log show` without --info - the
        // user reproducing "black screen, no error" needs this line.
        log.error("""
            bytes received but no decoded output: decodeIdle=\(decodeIdle, privacy: .public)s \
            receiveIdle=\(receiveIdle, privacy: .public)s (host is sending data we cannot decode - corrupt bitstream, missing IDR, \
            or codec mismatch)
            """)
        // Mirror into the in-app LogStore so the decode-only stall is visible in
        // Troubleshooting → Logs (which reads only Diag.*).
        Diag.warn(
            "Bytes received but no decoded output: decodeIdle=\(decodeIdle)s "
            + "receiveIdle=\(receiveIdle)s (host is sending data we cannot decode "
            + "- corrupt bitstream, missing IDR, or codec mismatch)",
            "Stream")
    }

    /// Decode resumed: clear the stall latches so a later stall logs and recovers afresh, and hide the
    /// hold banner. A reconnect episode owns its banner until it resumes or gives up.
    fileprivate func clearDecodeOnlyStallLatch() async {
        resetStallLatches()
        didReconnectForDecodeStall = false
        guard !isReconnecting else { return }
        let winForHide = window
        await MainActor.run { winForHide?.reconnectBanner.setVisible(false) }
    }

    func resetStallLatches() {
        didLogDecodeOnlyStall = false
        didAttemptStallRecovery = false
        didLogWatchdogHold = false
        didLogDownshiftDecision = false
        stallNudge = DecodeStallNudge()
        stallStartPackets = nil
    }

    /// Ask for a keyframe on the nudge schedule while decode is silent. Teardown is not time-bound here:
    /// the hold keeps the session while the control link lives, and dead-peer detection ends it.
    fileprivate func attemptDecodeStallRecovery(decodeIdle: Double, receiveIdle: Double) async {
        guard isStreaming, !stopInProgress, !isReconnecting else { return }
        // Packets arriving on a remote path mean overload, and a keyframe only adds to it; the downshift
        // tier owns that case. A silent PC is a paused encoder that a keyframe can wake.
        let overloaded = isRemotePathSession && receiveIdle < Self.decodeOnlyStallThreshold
        if !overloaded, stallNudge.due(at: decodeIdle) { backend.requestIdrFrame() }
        if didAttemptStallRecovery { return }
        didAttemptStallRecovery = true
        let stalled = String(format: "%.0f", decodeIdle)
        if overloaded {
            Diag.notice("Video stalled \(stalled)s with packets still arriving on a remote path - not asking for "
                + "keyframes (they would only add load); the bitrate downshift decides at "
                + "\(Int(BitrateDownshiftController.stallSecondsBeforeDownshift))s.", "Stream")
        } else {
            Diag.notice("Video stalled \(stalled)s - asking for a keyframe now, then at 4, 8 and every 16 s "
                + "(the PC may have paused video, as at the Windows sign-in screen); holding the session "
                + "while the control link stays alive.", "Stream")
        }
    }

    private func handleWatchdogTimeout(
        decodeIdleSeconds: Double, receiveIdleSeconds: Double,
        neverDecodedFirstFrame: Bool = false
    ) async {
        // A reconnect episode has the connection down on purpose and owns the bounded give-up.
        guard isStreaming, !stopInProgress, !isReconnecting else { return }

        // HOLD-IF-ALIVE: a 10 s stall with fresh ENet ACKs is a paused encoder (the Windows sign-in
        // desktop), not a dead session; ENet's dead-peer detection owns that teardown. A connection
        // that never showed frame one is a broken bring-up and gets no hold.
        if !neverDecodedFirstFrame,
           let health = backend.enetHealth(),
           health.sinceLastAckMs < StreamSession.enetAliveHoldThresholdMs {
            await holdForAliveLink(
                decodeIdle: decodeIdleSeconds, receiveIdle: receiveIdleSeconds, ackMs: health.sinceLastAckMs)
            return
        }

        let receiveDesc = receiveIdleSeconds.isFinite
            ? "\(receiveIdleSeconds)s"
            : "never"
        log.error("""
            Frame watchdog tripped - no decoded frame in \(decodeIdleSeconds)s (last byte reception \
            \(receiveDesc, privacy: .public)); tearing down
            """)
        // Troubleshooting → Logs reads only Diag.*, so the stop says why it ran.
        Diag.error(
            "Frame watchdog tripped: no decoded frame in \(decodeIdleSeconds)s "
            + "(last byte reception \(receiveDesc)) - tearing down",
            "Stream")
        // Latch the stall before the synthetic terminate so the cause is the stall, not the code.
        noteTelemetryDisconnect(.watchdogStall)
        let code = Self.watchdogTerminationCode(
            neverDecodedFirstFrame: neverDecodedFirstFrame, receiveIdleSeconds: receiveIdleSeconds)
        bridge?.eventContinuation?.yield(.connectionTerminated(errorCode: code))
        await stop()
    }

    /// The control link is alive, so hold. Nothing received means the PC paused video; packets that never
    /// decode mean a fault on this side, which one reconnect in place rebuilds.
    private func holdForAliveLink(decodeIdle: Double, receiveIdle: Double, ackMs: UInt32) async {
        let winForHold = window
        await MainActor.run {
            winForHold?.reconnectBanner.setText("Waiting for video…")
            winForHold?.reconnectBanner.setVisible(true)
        }
        let receiving = receiveIdle < Self.decodeOnlyStallThreshold
        if receiving, decodeIdle >= Self.decodeOnlyReconnectSeconds, !didReconnectForDecodeStall {
            didReconnectForDecodeStall = true
            Diag.warn("Receiving \(stallPacketRate()) but nothing decoded for \(Int(decodeIdle))s "
                + "(\(decoderStateSummary())) - rebuilding the decoder with a reconnect in place.", "Stream")
            await runSelfInitiatedReconnect(cause: "video arrived for \(Int(decodeIdle))s without decoding")
            return
        }
        guard !didLogWatchdogHold else { return }
        didLogWatchdogHold = true
        if receiving {
            let state = decoderStateSummary()
            log.notice("""
                Frame watchdog: receiving \(self.stallPacketRate(), privacy: .public) but not decoding for \
                \(decodeIdle)s (receive idle \(receiveIdle)s; \(state, privacy: .public)); control link alive (ACK \
                \(ackMs, privacy: .public)ms ago) - holding, reconnect at \(Self.decodeOnlyReconnectSeconds)s
                """)
            Diag.notice("Receiving \(stallPacketRate()) but not decoding for \(Int(decodeIdle))s (\(state)); the "
                + "connection is alive, so holding and rebuilding the decoder with a reconnect at "
                + "\(Int(Self.decodeOnlyReconnectSeconds))s.", "Stream")
        } else {
            log.notice("""
                Frame watchdog: no decoded frame in \(decodeIdle)s and no video packets for \(receiveIdle)s, but \
                control link alive (ACK \(ackMs, privacy: .public)ms ago) - holding, not tearing down (the PC likely \
                paused video for a sign-in or desktop switch); keyframe requests back off
                """)
            Diag.notice("Video stalled \(Int(decodeIdle))s with no packets for \(Int(receiveIdle))s, but the "
                + "connection is alive - holding and asking for keyframes (the PC likely paused video for a "
                + "sign-in or desktop switch). Will reconnect only if the PC goes silent.", "Stream")
        }
    }

    /// Video packets per second since the stall was first logged, for the hold line.
    private func stallPacketRate() -> String {
        guard let start = stallStartPackets else { return "video packets" }
        let elapsed = ProcessInfo.processInfo.systemUptime - start.uptime
        guard elapsed >= 1 else { return "video packets" }
        let rate = Double(TelemetryCounters.shared.videoPacketsTotal.value &- start.total) / elapsed
        return "\(Int(rate)) video pkts/s"
    }

    private func decoderStateSummary() -> String {
        guard let dec = videoDecoder else { return "decoder gone" }
        let stats = dec.telemetryStatsSnapshot()
        return "decoder: \(dec.inFlightDecodeBacklog()) in flight, \(Int(stats.receivedFps ?? 0)) fps assembled, "
            + "\(Int(stats.decodedFps ?? 0)) fps decoded, \(dec.telemetryDecoderDrops()) dropped"
    }
}
