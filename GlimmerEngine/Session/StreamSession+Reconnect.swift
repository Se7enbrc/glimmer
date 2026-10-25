// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// Rebuild a failed live connection under the retained frame within one bounded recovery episode.
// Keep native media and input ownership until recovery succeeds or final teardown completes.

import Foundation
import QuartzCore
import os

extension StreamSession {

    /// Entry point for a host-initiated TERMINATION (routed here from
    /// `NativeBackend.connectionTerminated`). Classifies recoverable-vs-fatal and
    /// either drives a silent reconnect episode or tears down as before.
    package func handleHostTerminate(code: Int32, from source: NativeBackend? = nil) async {
        guard source == nil || source === backend,
              isStreaming, !stopInProgress else { return }
        // The uplink is dead the instant the host closed - pause input so we
        // don't spew sends at a gone backend. It re-arms on the next
        // `.connectionEstablished` (nativeConnectionEstablished → setReady(true)).
        publicInput?.prepareForReplacement(attempt: attemptID)
        let inp = input
        // FIFO main-queue hop (NOT Task{}) so this pause can't reorder ahead of the
        // reconnect's setReady(true) - see nativeConnectionEstablished.
        DispatchQueue.main.async { MainActor.assumeIsolated { inp?.setReady(false) } }

        if isReconnecting {
            if reconnectTermination == nil { reconnectTermination = (attemptID, code) }
            return
        }

        // Recovery needs an earlier live connection and a transient termination cause.
        // Startup failures and terminal PC errors still take the normal teardown path.
        let recoverable = Self.canRecoverTermination(code) && reachedLiveState
        guard recoverable else {
            bridge?.emit(.connectionTerminated(errorCode: code))
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

    private static func canRecoverTermination(_ code: Int32) -> Bool {
        recoverableTerminationCodes.contains(code) || code == deadPeerTerminationCode
    }

    /// Whether the PC ended the session on purpose: it answered and no longer
    /// runs our app (0 after a quit on the PC or Force Stop, another id after a
    /// takeover). No answer means Sunshine is restarting, which a reconnect rides out.
    package static func pcEndedSession(runningAppID: Int?, appID: Int?) -> Bool {
        guard let runningAppID, let appID else { return false }
        return runningAppID != appID
    }

    /// Why the episode's log line says the link went away: -1 is our own link
    /// dropping, not the PC restarting.
    package static func reconnectCause(code: Int32) -> String {
        if code == deadPeerTerminationCode { return "our link to the PC dropped (code -1)" }
        return "the PC closed the live stream (code 0x\(String(UInt32(bitPattern: code), radix: 16))), "
            + "likely restarting across a lock or desktop switch"
    }

    /// One quick /serverinfo: the app the PC runs now, or nil if it didn't
    /// answer in time.
    private func probeRunningAppID() async -> Int? {
        guard let server = reconnectServer else { return nil }
        let deadline = Date().addingTimeInterval(Self.hostEndProbeSeconds)
        let net = makeNetwork(server)
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
        bridge?.emit(.connectionTerminated(errorCode: 0))
        await stop(cause: .hostClosedClean)
    }

    /// Decoder stalls share the termination recovery owner and retain the native surface.
    /// Bitrate requests enter through the resume-only actuator instead.
    package func runSelfInitiatedReconnect(
        cause: String, bannerText: String = "Reconnecting…",
        rearmWatchdog: @Sendable (StreamSession) async -> Void = StreamSession.rearmReconnectWatchdog
    ) async {
        guard isStreaming, !stopInProgress, !isReconnecting else { return }
        publicInput?.prepareForReplacement(attempt: attemptID)
        let inp = input
        DispatchQueue.main.async { MainActor.assumeIsolated { inp?.setReady(false) } }
        await runReconnectEpisode(code: Self.deadPeerTerminationCode, cause: cause,
                                  bannerText: bannerText, rearmWatchdog: rearmWatchdog)
    }

    /// Drive a bounded reconnect episode: hold the frozen frame and retry the
    /// in-place rebuild with a short backoff, then resume (`.reconnected`) or,
    /// once the attempts or the awake-time budget run out, tear down for real.
    package func runReconnectEpisode(
        code: Int32, cause: String, bannerText: String = "Reconnecting…",
        rearmWatchdog: @Sendable (StreamSession) async -> Void = StreamSession.rearmReconnectWatchdog
    ) async {
        isReconnecting = true
        setWaitingForVideo(false)
        reconnectAttempts = 0
        lastReconnectError = nil
        let budget = ReconnectBudget(seconds: Self.reconnectWindowSeconds)
        if bitrateChange == nil { bridge?.emit(.reconnecting) }
        // Surface the hold over the frozen frame - the launcher's phase chip is
        // occluded by the fullscreen window, so this banner is the only in-stream
        // signal that we're holding rather than dead. It announces itself.
        let winForBanner = bitrateChange == nil ? presentation : nil
        await MainActor.run {
            winForBanner?.showRecovery(bannerText)
        }
        Diag.notice("Reconnecting in place, holding the last frame: \(cause).", "Stream")

        var pcMovedOn = false
        var terminationCode = code
        while isStreaming, !stopInProgress,
              reconnectAttempts < Self.reconnectAttemptCap, let budgetEnd = budget.deadline() {
            reconnectAttempts += 1
            // A healthy bitrate transition starts immediately. Failed attempts back off while Sunshine settles.
            let delayMs: UInt64 = bitrateChange != nil && reconnectAttempts == 1
                ? 0 : UInt64(min(reconnectAttempts, 3)) * 800
            do {
                let delay = min(Double(delayMs) / 1000, max(0, budgetEnd.timeIntervalSinceNow))
                try await clock.sleep(.seconds(delay))
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
            if resumed, await finishReconnect(attempt: attemptID, rearmWatchdog: rearmWatchdog) { return }
            if let failure = reconnectTermination, failure.attempt == attemptID {
                terminationCode = failure.code
                lastReconnectError = nil
                if !Self.canRecoverTermination(failure.code) { break }
            }
        }

        // Exhausted the budget (or the user quit mid-episode). Give up to a real
        // teardown so the launcher shows the session ended.
        defer { isReconnecting = false }
        let winForGiveup = presentation
        await MainActor.run { winForGiveup?.showRecovery(nil) }
        guard isStreaming, !stopInProgress else { return }
        if pcMovedOn {
            Diag.notice("reconnect: the PC is running another app now - ending the stream.", "Stream")
            await endStreamClosedByPC()
            return
        }
        Diag.error(
            "reconnect exhausted after \(reconnectAttempts) attempt(s) - tearing down",
            "Stream")
        bridge?.emit(.connectionTerminated(errorCode: terminationCode, error: lastReconnectError))
        await stop(cause: terminationCode == 0 ? .hostClosedClean : .hostError)
    }

    package static func rearmReconnectWatchdog(_ session: StreamSession) async {
        await MainActor.run { session.frameWatchdogArmedAt = session.uptimeSeconds }
    }

    /// Each main-actor suspension can overlap stop or another attempt; publish only the surviving recovery.
    @discardableResult
    package func finishReconnect(
        attempt: UUID,
        rearmWatchdog: @Sendable (StreamSession) async -> Void = StreamSession.rearmReconnectWatchdog
    ) async -> Bool {
        guard isStreaming, !stopInProgress, attempt == attemptID,
              reconnectTermination?.attempt != attempt else { return false }
        await rearmWatchdog(self)
        guard isStreaming, !stopInProgress, attempt == attemptID,
              reconnectTermination?.attempt != attempt else { return false }
        if bitrateChange != nil {
            publicInput?.resumeAfterReplacement(attempt: attempt)
            let inp = input
            let gate = bridge
            await MainActor.run {
                if gate?.acceptsInput(attempt: attempt) == true { inp?.setReady(true) }
            }
            guard isStreaming, !stopInProgress, attempt == attemptID,
                  reconnectTermination?.attempt != attempt else { return false }
        }
        if bitrateChange != nil {
            completeBitrateChange(.applied)
            bitrateChange = nil
        }
        isReconnecting = false
        reconnectAttempts = 0
        // Connect-start reanchors handshake telemetry, so its established edge cannot count this recovery.
        TelemetryCounters.shared.reconnectTotal.increment()
        bridge?.emit(.reconnected, attempt: attempt)
        let winForHide = presentation
        await MainActor.run { winForHide?.showRecovery(nil) }
        guard isStreaming, !stopInProgress, !isReconnecting, attempt == attemptID else { return true }
        Diag.notice("reconnected - stream resumed in place", "Stream")
        resetStallLatches()
        return true
    }

    /// What a failed attempt tells the user if the episode gives up. A deadline the PC never answered
    /// inside means the PC is gone (asleep, off the network), not an app slow to start.
    package static func reconnectAttemptError(_ error: Error, pcAnswered: Bool) -> StreamError? {
        guard let streamError = error as? StreamError else { return nil }
        if case .hostTimedOut = streamError, !pcAnswered {
            return .hostUnreachable("the PC didn't answer during the reconnect")
        }
        return streamError
    }

    /// Replace transport without replacing the native surface or input registrations.
    private func reconnectInPlace(deadline: Date) async throws(TakeoverRequired) -> Bool {
        guard !Task.isCancelled, isStreaming, !stopInProgress, Date() < deadline else { return false }
        if bitrateChange == nil { await refreshReconnectAsk() }
        guard !Task.isCancelled, isStreaming, !stopInProgress, Date() < deadline,
              let server = reconnectServer, var config = reconnectConfig, let appID = reconnectAppID,
              let win = presentation, let inp = input, let dec = videoDecoder else { return false }
        if let change = bitrateChange {
            config.bitrateKbps = change.report.requestedKbps
            config.bitrateBoost = 1
            config.width = change.report.width ?? config.width
            config.height = change.report.height ?? config.height
        }
        let setup = SessionMedia(presentation: win, input: inp, video: dec)
        do {
            await releaseReconnectInput()
            try await prepareBitrateMedia()
            let teardownStart = uptimeSeconds
            await teardownConnectionForReconnect()
            bitrateChange?.report.legs["teardown_ms", default: 0] += (uptimeSeconds - teardownStart) * 1_000
            try checkAttempt(deadline: deadline)
            let fresh = makeBackend()
            backend = fresh
            await bindReplacement(fresh, setup: setup, config: config)
            try checkAttempt(deadline: deadline)
            return try await connectReplacement(server: server, appID: appID, config: config,
                setup: setup, fresh: fresh, deadline: deadline)
        } catch let takeover as TakeoverRequired {
            throw takeover
        } catch {
            lastReconnectError = Self.reconnectAttemptError(error, pcAnswered: false)
            return false
        }
    }

    private func bindReplacement(_ fresh: StreamingBackend, setup: SessionMedia, config: StreamRequest) async {
        attemptID = UUID()
        reconnectTermination = nil
        #if os(macOS) || GLIMMER_DIAGNOSTICS
        if let tracker = FrameTimingTracker.shared {
            if let pacer = setup.video.framePacer {
                _ = pacer.clearQueue(reason: "telemetry attempt boundary") { tracker.beginAttempt(attemptID) }
            } else {
                tracker.beginAttempt(attemptID)
            }
        }
        #endif
        bridge?.beginAttempt(attemptID)
        publicInput?.rebind(to: fresh, attempt: attemptID, holdActivation: bitrateChange != nil)
        await MainActor.run {
            setup.input.setBackend(fresh)
            setup.video.setBackend(fresh)
            setup.input.configure(config)
        }
        guard isStreaming, !stopInProgress, !Task.isCancelled else { return }
        if let bridge {
            await wireMediaCallbacks(setup: setup, bridge: bridge, attempt: attemptID,
                suppressFirstFrame: bitrateChange != nil)
        }
    }

    private func connectReplacement(server: ServerInfo, appID: Int, config: StreamRequest,
                                    setup: SessionMedia, fresh: StreamingBackend, deadline: Date) async throws -> Bool {
        let net = makeNetwork(server)
        network = net
        await net.setRequestDeadline(deadline)
        var pcAnswered = false
        do {
            try checkAttempt(deadline: deadline)
            let statusStart = uptimeSeconds
            let serverInfo = try await StreamAttempt.run(until: deadline) { try await net.fetchServerInfo() }
            pcAnswered = true
            try checkAttempt(deadline: deadline)
            bitrateChange?.report.legs["server_info_ms", default: 0] += (uptimeSeconds - statusStart) * 1_000
            if serverInfo.currentGameID != appID { ownsHostSession = false }
            if hostDisposition.cancellation == nil, serverInfo.currentGameID != 0,
               serverInfo.currentGameID != appID { throw TakeoverRequired(appID: serverInfo.currentGameID) }
            let launch: LaunchResponse
            if bitrateChange != nil {
                launch = try await resumeForBitrateChange(network: net, appID: appID,
                    config: config, info: serverInfo, deadline: deadline)
            } else {
                launch = try await launchWithDeadline(
                    network: net, appID: appID, config: config, info: serverInfo, deadline: deadline)
            }
            try checkAttempt(deadline: deadline)
            if publicMedia != nil { try launch.validateSessionKey() }
            let backendConfig = makeBackendConfig(config: config, launch: launch, server: serverInfo,
                                                   exactBitrate: bitrateChange != nil)
            let transportStart = uptimeSeconds
            try await connectBackend(serverInfo: serverInfo, launch: launch, backendConfig: backendConfig,
                setup: setup, network: net, duringReconnect: true, deadline: deadline)
            bitrateChange?.report.legs["transport_ms", default: 0] += (uptimeSeconds - transportStart) * 1_000
            fresh.requestIdrFrame()
            try await waitForBitrateMedia(deadline: deadline)
            try checkAttempt(deadline: deadline)
            await net.setRequestDeadline(nil)
            try checkAttempt(deadline: deadline)
            setup.video.setNegotiatedBitrateKbps(Int(backendConfig.bitrate))
            return true
        } catch {
            Diag.notice("reconnect attempt failed: \(error, privacy: .private)", "Stream")
            lastReconnectError = Self.reconnectAttemptError(error, pcAnswered: pcAnswered)
            fresh.interruptConnection()
            await net.shutdown()
            if network === net { network = nil }
            if let takeover = error as? TakeoverRequired { throw takeover }
            return false
        }
    }

    /// The ask for the route the Mac is on now, or nil when unknown (no provider, another PC selected).
    package func currentRouteAsk() async -> RouteAsk? {
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

    /// Releases must be sent while the old uplink still accepts reliable input.
    private func releaseReconnectInput() async {
        if bitrateChange != nil { videoDecoder?.retainImageForReconnect.store(true, ordering: .releasing) }
        if bitrateChange?.inputDisabledAt == nil { bitrateChange?.inputDisabledAt = uptimeSeconds }
        publicInput?.prepareForReplacement(attempt: attemptID)
        let prepared = input
        await MainActor.run { prepared?.quiesce(); prepared?.setReady(false) }
    }

    private func teardownConnectionForReconnect() async {
        backend.stopConnection()
        _ = videoDecoder?.framePacer?.clearQueue(reason: "connection replacement")
        if bitrateChange?.report.attempts == 1 {
            bitrateChange?.oldLastFrame = videoDecoder?.statsCollector.presentationTimes.last
        }
        if let net = network { await net.shutdown() }
        network = nil
        #if os(macOS) || GLIMMER_DIAGNOSTICS
        if let state = connectFlowState {
            OSSignposter.network.endInterval("ConnectFlow", state, "outcome=reconnect")
            connectFlowState = nil
        }
        #endif
    }
}

/// A reconnect episode's time budget, counted in awake time so a lid closed
/// mid-episode doesn't spend it. Each pass turns what's left into a wall-clock
/// deadline; an attempt in flight across sleep fails on its stale one.
package struct ReconnectBudget {
    package let end: SuspendingClock.Instant

    package init(seconds: TimeInterval, now: SuspendingClock.Instant = .now) {
        end = now.advanced(by: .seconds(seconds))
    }

    /// Nil once the awake budget is spent.
    package func deadline(now: SuspendingClock.Instant = .now, wallNow: Date = Date()) -> Date? {
        let left = now.duration(to: end)
        return left > .zero ? wallNow.addingTimeInterval(left / .seconds(1)) : nil
    }
}
