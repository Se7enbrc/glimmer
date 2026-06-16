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
        Task { @MainActor in inp?.setReady(false) }

        // Nothing to recover if the user is already tearing down, or we're not
        // (or no longer) the live session.
        guard isStreaming, !stopInProgress else { return }
        // An episode is already being driven - its retry loop owns the outcome.
        // A re-terminate fired by the dead/old backend (or a failed reconnect
        // attempt) must not start a second episode.
        guard !isReconnecting else { return }

        // Recoverable iff the host sent the "server terminated this session"
        // code AND we'd already reached a live state. A terminate before first
        // live edge is a failed connect, not an interruption - fall through to
        // the original teardown so the launcher shows the honest failure.
        let recoverable = code == Self.recoverableTerminationCode && reachedLiveState
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
                bridge?.eventContinuation?.yield(.reconnected)
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

        // 2. Swap in a fresh backend (NativeBackend is one-shot: its connection
        //    state can't be reused and interrupt() latches permanently). Re-point
        //    input + decoder on the MainActor so uplink + IDR requests go to the
        //    new backend, not the dead one.
        let fresh = NativeBackend()
        self.backend = fresh
        await MainActor.run {
            inp.setBackend(fresh)
            dec.setBackend(fresh)
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

        // 4. Nudge a keyframe so the fresh VT session repaints over the frozen
        //    frame promptly (Sunshine sends one at start; cheap insurance).
        backend.requestIdrFrame()
        return true
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
