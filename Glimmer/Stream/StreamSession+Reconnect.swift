// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  StreamSession+Reconnect.swift
//
//  Silent reconnect-as-stall. When the host closes a LIVE session with a
//  recoverable code - Sunshine's process restarting across a Windows lock /
//  secure-desktop transition (it returns in ~3s), or a brief network blip -
//  we DON'T bounce to the launcher and DON'T sit through the watchdog's 10s
//  freeze-then-teardown. Instead we hold the frozen last frame on screen and
//  silently re-establish the connection underneath it, resuming in place when
//  video flows again (matching Moonlight's "hang then resume"). Only on
//  give-up (attempts/window exhausted) do we tear down for real.
//
//  This is possible because the frozen frame survives a connection teardown:
//  backend.stopConnection() runs the decoder's sink stop()/cleanup() (which
//  only invalidate the VideoToolbox session + param sets), but NOT
//  VideoDecoder.teardown() or StreamWindow.close() - so the
//  AVSampleBufferDisplayLayer keeps its last image until a fresh setup() +
//  IDR repaints over it. We keep the window, decoder, input forwarder, the
//  retained bridge, StreamBridgeContext.current, and the event stream alive
//  across the rebuild; only the backend connection + NetworkClient are
//  replaced.
//

import Foundation
import QuartzCore
import os

extension StreamSession {

    /// Entry point for a host-initiated TERMINATION (routed here from
    /// `NativeBackend.connectionTerminated`). Classifies recoverable-vs-fatal and
    /// either drives a silent reconnect episode or tears down as before.
    func handleHostTerminate(code: Int32, from source: NativeBackend? = nil) async {
        guard source == nil || source === backend,
              isStreaming, !stopInProgress, !isReconnecting else { return }
        // The uplink is dead the instant the host closed - pause input so we
        // don't spew sends at a gone backend. It re-arms on the next
        // `.connectionEstablished` (nativeConnectionEstablished → setReady(true)).
        let inp = input
        // FIFO main-queue hop (NOT Task{}) so this pause can't reorder ahead of the
        // reconnect's setReady(true) - see nativeConnectionEstablished.
        DispatchQueue.main.async { MainActor.assumeIsolated { inp?.setReady(false) } }

        // Recoverable iff we'd already reached a live state AND the cause is one we
        // can resume from: a host terminate in the recoverable set (server restart /
        // graceful), or OUR OWN ENet dead-peer self-terminate (-1, the radio-doze /
        // link-blip case). A terminate before the first live edge is a failed
        // connect, not an interruption - fall through to the honest teardown so the
        // launcher shows the failure. The 10s dead-peer envelope is unchanged; this
        // only chooses silent-reconnect over teardown once it has fired.
        let recoverableCause = Self.recoverableTerminationCodes.contains(code)
            || code == Self.deadPeerTerminationCode
        let recoverable = recoverableCause && reachedLiveState
        guard recoverable else {
            bridge?.eventContinuation?.yield(.connectionTerminated(errorCode: code))
            await stop(cause: code == 0 ? .hostClosedClean : .hostError)
            return
        }

        // Our own dead-peer (-1) says nothing about the PC. A code the PC sent may
        // mean it ended the session on purpose, so ask before relaunching anything.
        if code != Self.deadPeerTerminationCode {
            isReconnecting = true   // the probe owns the outcome; re-entrant terminates wait
            let runningAppID = await probeRunningAppID()
            isReconnecting = false
            guard isStreaming, !stopInProgress else { return }
            if Self.pcEndedSession(runningAppID: runningAppID, appID: reconnectAppID) {
                Diag.notice("The PC ended the session (code 0x\(String(UInt32(bitPattern: code), radix: 16)), "
                    + "now running app \(runningAppID ?? 0)) - ending the stream, not reconnecting.", "Stream")
                await endStreamClosedByPC()
                return
            }
        }
        await runReconnectEpisode(code: code, cause: Self.reconnectCause(code: code))
    }

    /// Whether the PC ended the session on purpose: it answered and no longer
    /// runs our app (0 after a quit on the PC or Force Stop, another id after a
    /// takeover). No answer means Sunshine is restarting, which a reconnect rides out.
    static func pcEndedSession(runningAppID: Int?, appID: Int?) -> Bool {
        guard let runningAppID, let appID else { return false }
        return runningAppID != appID
    }

    /// Why the episode's log line says the link went away: -1 is our own link
    /// dropping, not the PC restarting.
    static func reconnectCause(code: Int32) -> String {
        if code == deadPeerTerminationCode { return "our link to the PC dropped (code -1)" }
        return "the PC closed the live stream (code 0x\(String(UInt32(bitPattern: code), radix: 16))), "
            + "likely restarting across a lock or desktop switch"
    }

    /// One quick /serverinfo: the app the PC runs now, or nil if it didn't
    /// answer in time.
    private func probeRunningAppID() async -> Int? {
        guard let server = reconnectServer else { return nil }
        let deadline = Date().addingTimeInterval(Self.hostEndProbeSeconds)
        let net = NetworkClient(server: server)
        await net.setRequestDeadline(deadline)
        let info = try? await StreamAttempt.run(until: deadline) { try await net.fetchServerInfo() }
        await net.shutdown()
        return info?.currentGameID
    }

    /// The PC ended the session on purpose: end it like a clean close, with no
    /// error banner and no /launch.
    private func endStreamClosedByPC() async {
        // Nothing of ours left to /cancel, and a /cancel would quit whatever
        // another device is streaming now.
        ownsHostSession = false
        hostSessionClientID = nil
        bridge?.eventContinuation?.yield(.connectionTerminated(errorCode: 0))
        await stop(cause: .hostClosedClean)
    }

    /// A reconnect this side chose on a live connection (a bitrate change, a decoder that never decodes
    /// what arrives). The same episode as a host terminate: the frozen frame holds under the banner and
    /// video resumes in place; the first `reconnectInPlace` brings the live connection down itself.
    func runSelfInitiatedReconnect(cause: String, bannerText: String = "Reconnecting…") async {
        guard isStreaming, !stopInProgress, !isReconnecting else { return }
        let inp = input
        DispatchQueue.main.async { MainActor.assumeIsolated { inp?.setReady(false) } }
        await runReconnectEpisode(code: Self.deadPeerTerminationCode, cause: cause, bannerText: bannerText)
    }

    /// Drive a bounded reconnect episode: hold the frozen frame and retry the
    /// in-place rebuild with a short backoff, then resume (`.reconnected`) or,
    /// once the attempts or the awake-time budget run out, tear down for real.
    private func runReconnectEpisode(code: Int32, cause: String, bannerText: String = "Reconnecting…") async {
        isReconnecting = true
        reconnectAttempts = 0
        lastReconnectError = nil
        let budget = ReconnectBudget(seconds: Self.reconnectWindowSeconds)
        bridge?.eventContinuation?.yield(.reconnecting)
        // Surface the hold over the frozen frame - the launcher's phase chip is
        // occluded by the fullscreen window, so this banner is the only in-stream
        // signal that we're holding rather than dead. It announces itself.
        let winForBanner = window
        await MainActor.run {
            winForBanner?.reconnectBanner.setText(bannerText)
            winForBanner?.reconnectBanner.setVisible(true)
        }
        Diag.notice("Reconnecting in place, holding the last frame: \(cause).", "Stream")

        var pcMovedOn = false
        while isStreaming, !stopInProgress,
              reconnectAttempts < Self.reconnectAttemptCap, let budgetEnd = budget.deadline() {
            reconnectAttempts += 1
            // Backoff: the host (Sunshine) is mid-restart and its HTTPS endpoint
            // may not answer for ~3s. A short ramp (0.8s, 1.6s, then 2.4s) keeps
            // the first resume snappy; launchWithBusyRecovery's own
            // waitForHostIdle poll absorbs the rest of the host's settle time.
            let delayMs = UInt64(min(reconnectAttempts, 3)) * 800
            do {
                let delay = min(Double(delayMs) / 1000, max(0, budgetEnd.timeIntervalSinceNow))
                try await Task.sleep(for: .seconds(delay))
            } catch {
                break
            }
            // Re-derive after the backoff: a lid closed during it spent no budget.
            guard !Task.isCancelled, isStreaming, !stopInProgress,
                  let deadline = budget.deadline() else { break }
            Diag.notice("reconnect attempt \(reconnectAttempts)/\(Self.reconnectAttemptCap)...", "Stream")
            let resumed: Bool
            do {
                resumed = try await reconnectInPlace(deadline: deadline)
            } catch {
                pcMovedOn = true
                break
            }
            if resumed {
                // The new connection's stats read as never decoded, so its
                // first-frame allowance starts here instead of at session start.
                await MainActor.run { self.frameWatchdogArmedAt = CACurrentMediaTime() }
                isReconnecting = false
                reconnectAttempts = 0
                // Count the genuine reconnect HERE. The established-edge inference
                // (markEstablishedReportingReconnect) can't: reconnectInPlace re-runs
                // connectBackend → anchorTelemetryConnectStart → p2.anchorReconnect(), which
                // wipes the established memory before the fresh edge fires, so that
                // path always reads the reconnect as a first connect. This site is
                // the unambiguous "a drop was silently recovered" signal.
                TelemetryCounters.shared.reconnectTotal.increment()
                bridge?.eventContinuation?.yield(.reconnected)
                let winForHide = window
                await MainActor.run { winForHide?.reconnectBanner.setVisible(false) }
                Diag.notice("reconnected - stream resumed in place", "Stream")
                // Re-arm the stall latches so a later stall logs/recovers fresh.
                resetStallLatches()
                return
            }
        }

        // Exhausted the budget (or the user quit mid-episode). Give up to a real
        // teardown so the launcher shows the session ended.
        isReconnecting = false
        let winForGiveup = window
        await MainActor.run { winForGiveup?.reconnectBanner.setVisible(false) }
        guard isStreaming, !stopInProgress else { return }
        if pcMovedOn {
            Diag.notice("reconnect: the PC is running another app now - ending the stream.", "Stream")
            await endStreamClosedByPC()
            return
        }
        Diag.error(
            "reconnect exhausted after \(reconnectAttempts) attempt(s) - tearing down",
            "Stream")
        bridge?.eventContinuation?.yield(.connectionTerminated(errorCode: code, error: lastReconnectError))
        await stop(cause: .hostError)
    }

    /// What a failed attempt tells the user if the episode gives up. A deadline the PC never answered
    /// inside means the PC is gone (asleep, off the network), not an app slow to start.
    static func reconnectAttemptError(_ error: Error, pcAnswered: Bool) -> StreamError? {
        guard let streamError = error as? StreamError else { return nil }
        if case .hostTimedOut = streamError, !pcAnswered {
            return .hostUnreachable("the PC didn't answer during the reconnect")
        }
        return streamError
    }

    /// One attempt: swap in a fresh backend and re-run the handshake, /launch and
    /// connect while the window, decoder and event stream stay alive. Returns true
    /// once back up; throws when the PC now runs another app.
    private func reconnectInPlace(deadline: Date) async throws(TakeoverRequired) -> Bool {
        guard !Task.isCancelled, isStreaming, !stopInProgress, Date() < deadline else { return false }
        await refreshReconnectAsk()
        guard !Task.isCancelled, isStreaming, !stopInProgress, Date() < deadline,
              let server = reconnectServer,
              let config = reconnectConfig,
              let appID = reconnectAppID,
              let win = window, let inp = input, let dec = videoDecoder else { return false }

        // 1. Bring the dead connection fully down (idempotent - onTerminated
        //    already called stopConnection). Keeps the window/decoder/frozen
        //    frame, the bridge + event stream, and StreamBridgeContext.current.
        await teardownConnectionForReconnect()

        // H5: re-check after the teardown await. stop() flips isStreaming/
        // stopInProgress synchronously before its own first await, so a guard
        // evaluated ON the actor between awaits reliably observes a teardown that
        // slipped in. Bail BEFORE building a fresh backend - nothing to clean up.
        guard !Task.isCancelled, isStreaming, !stopInProgress, Date() < deadline else { return false }

        // 2. Swap in a fresh backend (NativeBackend is one-shot: its connection
        //    state can't be reused and interrupt() latches permanently). Re-point
        //    input + decoder on the MainActor so uplink + IDR requests go to the
        //    new backend, not the dead one.
        let fresh = NativeBackend()
        self.backend = fresh
        await MainActor.run {
            inp.setBackend(fresh)
            dec.setBackend(fresh)
            // Re-derive the Cruise ceiling: reconnect reuses the forwarder and
            // never re-runs StartSetup, so a mid-session resolution change would
            // otherwise keep a stale gMax.
            CruiseTraversal.configure(inp, streamWidth: config.width)
            // Same reasoning for the absolute pointer's reference frame: a
            // reconnect at a new resolution would otherwise keep mapping
            // window points onto the old stream's pixel grid.
            inp.streamPixelSize = CGSize(width: config.width, height: config.height)
        }

        // 3. Fresh NetworkClient + full handshake against the restarted host.
        let net = NetworkClient(server: server)
        self.network = net
        await net.setRequestDeadline(deadline)
        let backendConfig: BackendStreamConfig
        var pcAnswered = false
        do {
            try checkAttempt(deadline: deadline)
            let serverInfo = try await StreamAttempt.run(until: deadline) {
                try await net.fetchServerInfo()
            }
            pcAnswered = true
            try checkAttempt(deadline: deadline)
            if serverInfo.currentGameID != appID { ownsHostSession = false }
            let launch = try await launchWithDeadline(
                network: net, appID: appID, config: config, info: serverInfo, deadline: deadline)
            try checkAttempt(deadline: deadline)
            // Re-probe the path on reconnect: the route may have moved (the
            // tunnel-flap case this whole clamp exists for), so remoteness and
            // the advertised packet size are resolved fresh, never inherited.
            backendConfig = makeBackendConfig(
                config: config, launch: launch, server: serverInfo)
            // duringReconnect: connectBackend's failure path must NOT run the
            // full stop() (that would blank the frozen frame + bounce to the
            // launcher) - it cancels the failed launch and throws so we retry.
            try await connectBackend(
                serverInfo: serverInfo, launch: launch, backendConfig: backendConfig,
                setup: (win, inp, dec), network: net, duringReconnect: true, deadline: deadline)
            try checkAttempt(deadline: deadline)
        } catch {
            Diag.notice("reconnect attempt failed: \(error, privacy: .private)", "Stream")
            lastReconnectError = Self.reconnectAttemptError(error, pcAnswered: pcAnswered)
            fresh.interruptConnection()
            await net.shutdown()
            if self.network === net { self.network = nil }
            if let takeover = error as? TakeoverRequired { throw takeover }
            return false
        }

        // H5: a stop() can land at ANY of the awaits above (~0.8-2.4s of handshake
        // per attempt, plus the frozen "Reconnecting..." banner invites a quit).
        // If one did, `fresh` + `net` are now a LIVE ENet/RTP backend on a session
        // with isStreaming=false and no teardown path - a zombie for the process
        // lifetime, with the host holding a "busy" session. interruptConnection()
        // (the permanent latch, drains the receive threads) + drop the client so
        // no live backend/NetworkClient survives the slipped-in stop. The episode
        // loop's own re-checks then exit; the existing stop() torn-down everything
        // else (window/decoder/bridge) already.
        guard isStreaming, !stopInProgress else {
            Diag.notice("reconnect: stop slipped in mid-handshake - "
                + "interrupting the freshly-built backend to kill the zombie connection", "Stream")
            await tearDownSlippedInReconnect(fresh: fresh, net: net)
            return false
        }

        await net.setRequestDeadline(nil)
        guard isStreaming, !stopInProgress, !Task.isCancelled else { return false }
        // The overlay and telemetry show what this connection asked for.
        dec.setNegotiatedBitrateKbps(Int(backendConfig.bitrate))

        // 4. Nudge a keyframe so the fresh VT session repaints over the frozen
        //    frame promptly (Sunshine sends one at start; cheap insurance).
        backend.requestIdrFrame()
        return true
    }

    /// The ask for the route the Mac is on now, or nil when unknown (no provider, another PC selected).
    func currentRouteAsk() async -> RouteAsk? {
        guard let provider = routeAskProvider else { return nil }
        return await MainActor.run { provider() }
    }

    /// Re-derive the ask for the route the Mac is on now. A downshift judged on this route stays the
    /// ceiling; one judged on another route is set aside, since it says nothing about this one.
    private func refreshReconnectAsk() async {
        let route = await currentRouteAsk()
        guard let config = reconnectConfig else { return }
        if let route, downshift.isDownshifted, !downshift.covers(route: route.route) {
            Diag.notice("Route changed since the downshift (\(downshift.route ?? "unknown") → \(route.route)) - "
                + "asking for its full \(route.kbps / 1000) Mbps again.", "Stream")
            downshift = BitrateDownshiftController()
        }
        let ask = StreamPathMTU.reconnectAsk(
            current: RouteAsk(kbps: config.bitrateKbps, boost: config.bitrateBoost),
            route: route, downshifted: downshift.isDownshifted)
        if ask.kbps != config.bitrateKbps {
            Diag.notice("Reconnect ask for the current route: \(ask.kbps / 1000) Mbps "
                + "(was \(config.bitrateKbps / 1000)).", "Stream")
        }
        reconnectConfig?.bitrateKbps = ask.kbps
        reconnectConfig?.bitrateBoost = ask.boost
    }

    /// H5 cleanup: a `stop()` slipped in while this attempt was mid-handshake, so
    /// the just-built `fresh` backend + `net` client are live on an already-ended
    /// session. Interrupt the backend (permanent latch; drains the receive threads
    /// so no callback can fire after) and shut the client so the host drops its
    /// session record. Only nil `self.network` if it's still the one we built - a
    /// concurrent stop() may have already nil'd it.
    private func tearDownSlippedInReconnect(fresh: NativeBackend, net: NetworkClient) async {
        fresh.interruptConnection()
        await net.shutdown()
        if self.network === net { self.network = nil }
    }

    /// Connection-only teardown for a reconnect: bring the backend connection
    /// down and drop the NetworkClient WITHOUT the things `stop()` does that
    /// would end the session - no event-stream finish, no bridge release, no
    /// `StreamBridgeContext.current` clear, no window close, no decoder teardown,
    /// no power-assertion end, and crucially NO `/cancel` (the host session is
    /// already gone; a /cancel could race the host's freshly-restarted one -
    /// launchWithBusyRecovery does the proper /cancel+/launch on the new client).
    private func teardownConnectionForReconnect() async {
        backend.stopConnection()
        if let net = network { await net.shutdown() }
        network = nil
        if let state = connectFlowState {
            OSSignposter.network.endInterval("ConnectFlow", state, "outcome=reconnect")
            connectFlowState = nil
        }
    }
}

/// A reconnect episode's time budget, counted in awake time so a lid closed
/// mid-episode doesn't spend it. Each pass turns what's left into a wall-clock
/// deadline; an attempt in flight across sleep fails on its stale one.
struct ReconnectBudget {
    let end: SuspendingClock.Instant

    init(seconds: TimeInterval, now: SuspendingClock.Instant = .now) {
        end = now.advanced(by: .seconds(seconds))
    }

    /// Nil once the awake budget is spent.
    func deadline(now: SuspendingClock.Instant = .now, wallNow: Date = Date()) -> Date? {
        let left = now.duration(to: end)
        return left > .zero ? wallNow.addingTimeInterval(left / .seconds(1)) : nil
    }
}
