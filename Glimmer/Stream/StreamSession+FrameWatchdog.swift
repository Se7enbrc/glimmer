//
//  StreamSession+FrameWatchdog.swift
//
//  The FRAME-DECODE watchdog - the "did the user see a frame?" gate - and the
//  stall handlers it drives: the decode-only-stall diagnostic, the latch
//  clears, the active IDR recovery, and the hold-or-tear-down timeout path.
//  Split out of StreamSession+Watchdog.swift (pure move) to keep each unit
//  under the length limit; that file keeps the PRESENT-path watchdog, which
//  covers the stalls DOWNSTREAM of decode this one is structurally blind to.
//  See StreamSession.swift for the actor's stored state and lifetime contract.
//

import Foundation
import AppKit
import os

extension StreamSession {

    /// Install the frame-arrival watchdog. Polls every 1s on the main run
    /// loop; gates on `VideoDecoder.secondsSinceLastDecodedFrame()` so a
    /// host sending us packets we can't decode (corrupt bitstream, missing
    /// IDR, codec mismatch) trips the watchdog instead of leaving the user
    /// staring at a black screen while reception looks healthy.
    func startFrameWatchdog() async {
        let dec = videoDecoder
        await MainActor.run {
            self.frameWatchdogTimer?.invalidate()
            self.frameWatchdogArmedAt = CACurrentMediaTime()
            let timer = Timer.scheduledTimer(
                withTimeInterval: 1.0, repeats: true
            ) { [weak self, weak dec] _ in
                guard let dec else { return }
                // GATED ≠ STALLED. While the hidden-window decode gate is
                // engaged the decoder is deliberately fed nothing (receive/
                // RFI and audio keep flowing) - healthy-by-design, the exact
                // mirror of tickPresentWatchdog bailing while suppressed.
                // Bail BEFORE reading the idle clocks so a long gated span
                // can't trip the decode-only diagnostic or the teardown
                // timeout. No trip condition is loosened: an UNGATED decode
                // stall still trips on the unchanged thresholds below. And the
                // gate can never block TEARDOWN: stopConnection's sink-stop
                // clears it (clearDecodeGateForConnectionStop), so a host
                // terminate while the window is hidden still reaches the hard
                // trip below on the normal post-gate envelope.
                if dec.decodeGated { return }
                // After a gate lifts, secondsSinceLastDecodedFrame() still
                // carries the whole gated span - a 60s gate reads as 60s of
                // idle at the very next 1Hz tick, past frameWatchdogTimeout,
                // tearing the session down before the ~12ms resync IDR can
                // decode. Floor the idle clock at the gate-OFF edge instead
                // (infinity when no gate ever engaged, so min() is identity):
                // the watchdog re-arms honestly FROM the resume - a post-gate
                // IDR that genuinely never decodes still soft-trips 3s and
                // hard-trips 10s after refocus, exactly the normal envelope.
                let decodeIdle = min(
                    dec.secondsSinceLastDecodedFrame(),
                    dec.secondsSinceDecodeGateLifted())
                // .infinity means we've never decoded a frame. The bare
                // `return` here used to make EVERY trip below structurally
                // blind to a bring-up that hangs before frame one - black
                // screen until manual cancel - even though frameWatchdogTimeout
                // is documented as moonlight's FIRST_FRAME_TIMEOUT_SEC. Give
                // the pre-first-frame window its own envelope from the arm
                // instant (audit 2026-08-17): past the same timeout with
                // nothing EVER decoded, run the hard trip. The ENet-alive hold
                // deliberately does NOT apply to this case - a host that never
                // delivered frame ONE on a healthy control link is a broken
                // bring-up, not a paused sign-in desktop.
                guard decodeIdle.isFinite else {
                    guard let self else { return }
                    let sinceArm = CACurrentMediaTime() - self.frameWatchdogArmedAt
                    if self.frameWatchdogArmedAt > 0,
                       sinceArm > StreamSession.frameWatchdogTimeout {
                        let receiveIdle = dec.secondsSinceLastReceivedFrame()
                        Task { [weak self] in
                            await self?.handleWatchdogTimeout(
                                decodeIdleSeconds: sinceArm,
                                receiveIdleSeconds: receiveIdle,
                                neverDecodedFirstFrame: true)
                        }
                    }
                    return
                }
                let receiveIdle = dec.secondsSinceLastReceivedFrame()

                // Soft trip: reception healthy but decode silent → log a
                // public-privacy diagnostic so the user-visible black-
                // screen symptom shows up in the unified log with an
                // actionable cause. Hard trip below still runs.
                if decodeIdle > StreamSession.decodeOnlyStallThreshold,
                   receiveIdle.isFinite,
                   receiveIdle < StreamSession.decodeOnlyStallThreshold {
                    guard let self else { return }
                    Task { [weak self] in
                        await self?.handleDecodeOnlyStall(
                            decodeIdle: decodeIdle, receiveIdle: receiveIdle)
                    }
                } else if decodeIdle < StreamSession.decodeOnlyStallThreshold {
                    // Decode healthy this tick - clear the latch so a
                    // future stall logs a fresh diagnostic.
                    guard let self else { return }
                    Task { [weak self] in await self?.clearDecodeOnlyStallLatch() }
                }

                // ACTIVE RECOVERY: decode silent past the recovery
                // threshold - request an IDR each tick to prompt a host that
                // paused video (e.g. the Windows sign-in → desktop transition)
                // to resume, rather than freezing until a manual reconnect.
                // Covers the host-went-fully-silent case the soft trip above
                // (which needs reception alive) misses. Fires for the WHOLE
                // stall, not just up to frameWatchdogTimeout: when the control
                // link is alive the hard trip below now HOLDS rather than tears
                // down, so we must keep nudging the host for a keyframe past 10s
                // so video resumes promptly once the desktop returns. If frames
                // resume, decodeIdle drops and the latch clears.
                if decodeIdle > StreamSession.decodeStallRecoveryThreshold {
                    guard let self else { return }
                    Task { [weak self] in await self?.attemptDecodeStallRecovery(decodeIdle: decodeIdle) }
                }

                // Past the IDR nudge: bits arriving, none decoding, long enough
                // that keyframes have plainly failed - on a remote path the rate
                // is the only thing left to change (see +Downshift).
                if decodeIdle >= BitrateDownshiftController.stallSecondsBeforeDownshift {
                    Task { [weak self] in await self?.considerBitrateDownshift(
                        decodeIdle: decodeIdle, receiveIdle: receiveIdle) }
                }

                // Hard trip: decode silent past the teardown threshold.
                // Regardless of reception state - bytes-only-no-decode for
                // 10s is just as broken as silent-everything from the
                // user's point of view.
                guard decodeIdle > StreamSession.frameWatchdogTimeout else { return }
                guard let self else { return }
                Task { [weak self] in
                    guard let self else { return }
                    await self.handleWatchdogTimeout(
                        decodeIdleSeconds: decodeIdle,
                        receiveIdleSeconds: receiveIdle)
                }
            }
            timer.tolerance = 0.1
            self.frameWatchdogTimer = timer
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
        // .public privacy so this lands in `log show` without --info - the
        // user reproducing "black screen, no error" needs this line.
        log.error(
            // swiftlint:disable:next line_length
            "bytes received but no decoded output: decodeIdle=\(decodeIdle, privacy: .public)s receiveIdle=\(receiveIdle, privacy: .public)s (host is sending data we cannot decode - corrupt bitstream, missing IDR, or codec mismatch)"
        )
        // Mirror into the in-app LogStore so the decode-only stall is visible in
        // Troubleshooting → Logs (which reads only Diag.*).
        Diag.warn(
            "Bytes received but no decoded output: decodeIdle=\(decodeIdle)s "
            + "receiveIdle=\(receiveIdle)s (host is sending data we cannot decode "
            + "- corrupt bitstream, missing IDR, or codec mismatch)",
            "Stream")
    }

    /// Clear the stall latches when decode resumes, so a later stall logs a
    /// fresh diagnostic and re-attempts recovery.
    fileprivate func clearDecodeOnlyStallLatch() async {
        didLogDecodeOnlyStall = false
        didAttemptStallRecovery = false
        didLogWatchdogHold = false
        didLogDownshiftDecision = false
        // Video resumed - drop the hold banner (no-op if it was never shown).
        let winForHide = window
        await MainActor.run { winForHide?.reconnectBanner.setVisible(false) }
    }

    /// Active stall recovery: request an IDR to prompt the host to resume
    /// the video stream after it paused (e.g. the Windows sign-in → desktop
    /// transition stops the encoder briefly). Called each watchdog tick for the
    /// whole stall once past `decodeStallRecoveryThreshold`; the request is
    /// coalesced on the control channel so re-firing per tick is cheap, and we
    /// log once per episode (latched). If the host resumes, decode flows and
    /// `clearDecodeOnlyStallLatch` re-arms us. Teardown is NOT time-bound here:
    /// while the control link is alive the watchdog holds and keeps nudging;
    /// only a genuinely-gone host (ENet dead-peer detection) ends the session.
    fileprivate func attemptDecodeStallRecovery(decodeIdle: Double) async {
        guard isStreaming, !stopInProgress, !isReconnecting else { return }
        backend.requestIdrFrame()
        if didAttemptStallRecovery { return }
        didAttemptStallRecovery = true
        Diag.notice(
            "Video stalled \(String(format: "%.0f", decodeIdle))s - requesting IDR to recover "
            + "(host may have paused video, e.g. the Windows sign-in → desktop transition); "
            + "holding the session while the control link stays alive.",
            "Stream")
    }

    private func handleWatchdogTimeout(
        decodeIdleSeconds: Double, receiveIdleSeconds: Double,
        neverDecodedFirstFrame: Bool = false
    ) async {
        // While a reconnect episode is running the connection is deliberately
        // down (we're rebuilding it under the frozen frame); the episode owns
        // the bounded retry/give-up, so the watchdog must NOT race it to a
        // teardown. It re-arms naturally once frames resume.
        guard isStreaming, !stopInProgress, !isReconnecting else { return }

        // HOLD-IF-ALIVE: a 10s video stall is NOT proof the session is
        // dead. During a Windows sign-in → desktop transition the host pauses
        // the encoder (Sunshine can't capture the secure desktop) while its
        // ENet control loop keeps ACKing our 100ms keepalives - so the link is
        // plainly alive, only video is absent. Tearing down here would kill the
        // session exactly as the user finishes typing their password and the
        // desktop loads. Moonlight rides this out and resumes; so do we. If the
        // control link is unambiguously alive (ACK silence well under ENet's
        // 10s dead-peer timeout), HOLD: the recovery branch keeps requesting
        // IDRs every tick, and we wait for the desktop to return. The genuine
        // "host is gone" teardown is owned by ENet's own dead-peer detection
        // (EnetControlChannel+ControlLoop fires onTerminated(-1) once keepalives
        // stop being ACKed) - a connection-loss signal, not a video-stall one.
        // The pre-first-frame trip is EXEMPT from the hold: "sign-in desktop
        // paused the encoder" presupposes video once flowed. A host that never
        // delivered frame ONE on a healthy control link is a broken bring-up -
        // holding it just pins the black screen the trip exists to end.
        if !neverDecodedFirstFrame,
           let health = backend.enetHealth(),
           health.sinceLastAckMs < StreamSession.enetAliveHoldThresholdMs {
            // Hold banner over the frozen frame: "Holding..." since the control
            // link is alive (only video paused) - "Reconnecting..." is reserved
            // for the real reconnect episode. Hidden by clearDecodeOnlyStallLatch.
            let winForHold = window
            await MainActor.run {
                winForHold?.reconnectBanner.setText("Holding…")
                winForHold?.reconnectBanner.setVisible(true)
            }
            if !didLogWatchdogHold {
                didLogWatchdogHold = true
                log.notice(
                    // swiftlint:disable:next line_length
                    "Frame watchdog: no decoded frame in \(decodeIdleSeconds)s but control link is alive (ACK \(health.sinceLastAckMs, privacy: .public)ms ago) - holding, not tearing down (host likely paused video for a sign-in/desktop transition); requesting IDRs until it resumes"
                )
                Diag.notice(
                    "Video stalled \(Int(decodeIdleSeconds))s but the connection is "
                    + "alive - holding and requesting keyframes (host likely paused "
                    + "video for a sign-in / desktop transition). Will reconnect "
                    + "only if the host goes silent.",
                    "Stream")
            }
            return
        }

        let receiveDesc = receiveIdleSeconds.isFinite
            ? "\(receiveIdleSeconds)s"
            : "never"
        log.error(
            // swiftlint:disable:next line_length
            "Frame watchdog tripped - no decoded frame in \(decodeIdleSeconds)s (last byte reception \(receiveDesc, privacy: .public)); tearing down"
        )
        // Also surface to the in-app LogStore (the user's Troubleshooting → Logs
        // view reads ONLY Diag.*, not os.Logger), so a watchdog-triggered stop
        // shows WHY it ran instead of a bare "Stream session stopping".
        Diag.error(
            "Frame watchdog tripped: no decoded frame in \(decodeIdleSeconds)s "
            + "(last byte reception \(receiveDesc)) - tearing down",
            "Stream")
        // P2 DISCONNECT REASON: a watchdog teardown is a decode/present STALL -
        // latch it before the synthetic terminate + stop so the cause is attributed
        // to the stall, not the host-error code the synthetic terminate carries.
        noteTelemetryDisconnect(.watchdogStall)
        // Reuse `connectionTerminated` with a sentinel error code so UI
        // can show a "host became unreachable" message. -1 maps to the
        // existing "Stream ended unexpectedly" handler in AppModel.
        bridge?.eventContinuation?.yield(.connectionTerminated(errorCode: -1))
        await stop()
    }
}
