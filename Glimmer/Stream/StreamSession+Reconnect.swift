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
import SwiftUI
import os

extension StreamSession {

    /// Entry point for a host-initiated TERMINATION (routed here from
    /// `NativeBackend.connectionTerminated`). Classifies recoverable-vs-fatal and
    /// either drives a silent reconnect episode or tears down as before.
    func handleHostTerminate(code: Int32) async {
        // The uplink is dead the instant the host closed - pause input so we
        // don't spew sends at a gone backend. It re-arms on the next
        // `.connectionEstablished` (handleConnectionEdge → setReady(true)).
        let inp = input
        // FIFO main-queue hop (NOT Task{}) so this pause can't reorder ahead of the
        // reconnect's setReady(true) - see handleConnectionEdge.
        DispatchQueue.main.async { MainActor.assumeIsolated { inp?.setReady(false) } }

        // Nothing to recover if the user is already tearing down, or we're not
        // (or no longer) the live session.
        guard isStreaming, !stopInProgress else { return }
        // An episode is already being driven - its retry loop owns the outcome.
        // A re-terminate fired by the dead/old backend (or a failed reconnect
        // attempt) must not start a second episode.
        guard !isReconnecting else { return }

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

        await runReconnectEpisode(code: code)
    }

    /// Drive a bounded reconnect episode: hold the frozen frame, retry the
    /// in-place rebuild with a short backoff until it succeeds or we exhaust the
    /// attempt/time budget, then resume (`.reconnected`) or give up (real
    /// teardown). MainActor work happens inside `reconnectInPlace`.
    private func runReconnectEpisode(code: Int32) async {
        isReconnecting = true
        reconnectAttempts = 0
        let deadline = Date().addingTimeInterval(Self.reconnectWindowSeconds)
        bridge?.eventContinuation?.yield(.reconnecting)
        // Surface the hold over the frozen frame - the launcher's phase chip is
        // occluded by the fullscreen window, so this banner is the only in-stream
        // signal that we're holding rather than dead.
        let winForBanner = window
        await MainActor.run {
            winForBanner?.reconnectBanner.setText("Reconnecting...")
            winForBanner?.reconnectBanner.setVisible(true)
            // VoiceOver can't reach a CALayer banner by focus - announce the
            // reconnect explicitly (the most safety-critical in-stream state).
            AccessibilityNotification.Announcement("Reconnecting").post()
        }
        Diag.notice(
            "Host closed the live stream (code 0x\(String(UInt32(bitPattern: code), radix: 16))) "
            + "- reconnecting in place, holding the last frame (the host likely restarted "
            + "across a lock/desktop transition).",
            "Stream")

        while isStreaming, !stopInProgress,
              reconnectAttempts < Self.reconnectAttemptCap, Date() < deadline {
            reconnectAttempts += 1
            // Backoff: the host (Sunshine) is mid-restart and its HTTPS endpoint
            // may not answer for ~3s. A short ramp (0.8s, 1.6s, then 2.4s) keeps
            // the first resume snappy; launchWithBusyRecovery's own
            // waitForHostIdle poll absorbs the rest of the host's settle time.
            let delayMs = UInt64(min(reconnectAttempts, 3)) * 800
            try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
            if !isStreaming || stopInProgress { break }
            Diag.notice("reconnect attempt \(reconnectAttempts)/\(Self.reconnectAttemptCap)...", "Stream")
            if await reconnectInPlace() {
                isReconnecting = false
                reconnectAttempts = 0
                // Count the genuine reconnect HERE. The established-edge inference
                // (markEstablishedReportingReconnect) can't: reconnectInPlace re-runs
                // connectBackend → anchorTelemetryConnectStart → p2.reset(), which
                // wipes the established memory before the fresh edge fires, so that
                // path always reads the reconnect as a first connect. This site is
                // the unambiguous "a drop was silently recovered" signal.
                TelemetryCounters.shared.reconnectTotal.increment()
                bridge?.eventContinuation?.yield(.reconnected)
                let winForHide = window
                await MainActor.run { winForHide?.reconnectBanner.setVisible(false) }
                Diag.notice("reconnected - stream resumed in place", "Stream")
                // Re-arm the stall latches so a later stall logs/recovers fresh.
                didLogDecodeOnlyStall = false
                didAttemptStallRecovery = false
                didLogWatchdogHold = false
                return
            }
        }

        // Exhausted the budget (or the user quit mid-episode). Give up to a real
        // teardown so the launcher shows the session ended.
        isReconnecting = false
        let winForGiveup = window
        await MainActor.run { winForGiveup?.reconnectBanner.setVisible(false) }
        guard isStreaming, !stopInProgress else { return }
        Diag.error(
            "reconnect exhausted after \(reconnectAttempts) attempt(s) - tearing down",
            "Stream")
        bridge?.eventContinuation?.yield(.connectionTerminated(errorCode: code))
        await stop(cause: .hostError)
    }

    /// One reconnect attempt: tear down ONLY the dead connection, swap in a fresh
    /// backend, re-point input/decoder at it, and re-run the handshake +
    /// /launch + startConnection against the (restarted) host - all while the
    /// window, decoder, frozen frame, bridge, and event stream stay alive.
    /// Returns true once the connection is back up.
    private func reconnectInPlace() async -> Bool {
        guard isStreaming, !stopInProgress else { return false }
        guard let server = reconnectServer,
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
        guard isStreaming, !stopInProgress else { return false }

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
            inp.cruiseGMax = CruiseTraversal.gMax(forStreamWidth: config.width)
        }

        // 3. Fresh NetworkClient + full handshake against the restarted host.
        let net = NetworkClient(server: server)
        self.network = net
        do {
            let serverInfo = try await net.fetchServerInfo()
            let launch = try await launchWithBusyRecovery(
                network: net, appID: appID, config: config,
                hintCurrentGame: serverInfo.currentGameID)
            let backendConfig = makeBackendConfig(config: config, launch: launch)
            // duringReconnect: connectBackend's failure path must NOT run the
            // full stop() (that would blank the frozen frame + bounce to the
            // launcher) - it cancels the failed launch and throws so we retry.
            try await connectBackend(
                serverInfo: serverInfo, launch: launch, backendConfig: backendConfig,
                setup: (win, inp, dec), network: net, duringReconnect: true)
        } catch {
            Diag.notice("reconnect attempt failed: \(error)", "Stream")
            await net.shutdown()
            self.network = nil
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

        // 4. Nudge a keyframe so the fresh VT session repaints over the frozen
        //    frame promptly (Sunshine sends one at start; cheap insurance).
        backend.requestIdrFrame()
        return true
    }

    /// H5 cleanup: a `stop()` slipped in while this attempt was mid-handshake, so
    /// the just-built `fresh` backend + `net` client are live on an already-ended
    /// session. Interrupt the backend (permanent latch; drains the receive threads
    /// so no callback can fire after) and shut the client so the host drops its
    /// session record. Only nil `self.network` if it's still the one we built - a
    /// concurrent stop() may have already nil'd it.
    private func tearDownSlippedInReconnect(fresh: NativeBackend, net: NetworkClient) async {
        fresh.interruptConnection()
        try? await net.cancel()
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
