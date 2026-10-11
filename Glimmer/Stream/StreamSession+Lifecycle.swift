// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  StreamSession+Lifecycle.swift
//
//  Session teardown (stop/interrupt), resume and confirmed takeover.
//  Split out of StreamSession.swift to keep each unit focused; see that file for
//  the actor's stored state and the callback lifetime contract.
//

import Foundation
import AppKit
import os

extension StreamSession {

    // MARK: - Teardown

    /// Public teardown entry point. Attributes the teardown to a genuine user
    /// quit (`.userStopped`) - the public API is the quit hotkey / Cmd-Q /
    /// window-close path. Internal callers that know a more specific cause go
    /// through `stop(cause:)` (which this forwards to). `DisconnectReason` is
    /// an internal type, so it can't appear in a `public` signature's default
    /// argument; this thin public wrapper keeps the API surface stable.
    public func stop() async {
        await stop(cause: .userStopped)
    }

    /// Tear down the session.
    ///
    /// - Parameter cause: why the teardown was initiated. The P2 disconnect-
    ///   reason latch keeps the FIRST concrete reason, so a host terminate /
    ///   watchdog / connect-failure already latched at its own site still wins;
    ///   this only fills in the cause for the otherwise-reason-less teardown
    ///   paths. Callers pass the specific cause they know:
    ///     - quit hotkey / Cmd-Q / window close → `.userStopped`
    ///     - AsyncStream consumer dropped (onTermination) → `.consumerDropped`
    ///   Making a reason-less teardown of a HEALTHY stream distinguishable
    ///   from a genuine user quit in the scorecard fixes the prior single
    ///   default silently attributing a dropped consumer to the user.
    func stop(cause: DisconnectReason) async {
        guard isStreaming || stopInProgress else { return }
        if stopCause == nil { stopCause = cause }
        stopInProgress = true
        isStreaming = false
        initialServerInfoTask?.cancel()
        launchTask?.cancel()
        await teardown.run { await self.performStop(cause: cause) }
    }

    private func performStop(cause: DisconnectReason) async {
        // Remove the sleep/wake observers + cancel any in-flight wake probe FIRST,
        // so a wake landing mid-teardown can't arm a probe against a dying session
        // (the probe also re-checks the lifecycle flags, but this is the clean cut).
        teardownWakeObservers()

        log.info("Stream session stopping (cause=\(cause.label, privacy: .public))")
        Diag.notice("Stream session stopping (cause: \(cause.label))", "Stream")

        // SESSION RECEIPT (the one engine-side hook): capture the end-of-
        // session numbers BEFORE anything tears down - estimatedRtt() reads
        // the ENet control channel's always-live EWMA, which dies with the
        // connection, and the collector's byte total resets on the next
        // session. The UI side (AppModel's teardown cleanup)
        // finalizes the receipt after the event stream drains, which this
        // stop() strictly happens-before. See SessionReceiptStore.
        SessionReceiptStore.captureStreamEnd(
            rttMs: backend.estimatedRtt()?.rttMs,
            collector: videoDecoder?.statsCollector)

        // P2 DISCONNECT REASON: this teardown path is the generic "session is
        // ending" beat. Latch the caller's `cause` - but the latch keeps the
        // FIRST concrete reason (P2State.setDisconnectReason), so a host
        // terminate (.hostError/.hostClosedClean from connectionTerminated), a
        // watchdog stall, or a connect failure already latched at their own sites
        // BEFORE this win. So this only attributes the teardown when nothing
        // more specific was recorded first.
        noteTelemetryDisconnect(cause)

        // Stop the telemetry exporter early (all-interfaces HTTP listener + NDJSON +
        // 1Hz timer). Idempotent + no-op when telemetry was off. Done before the
        // backend teardown so its 1Hz capture can't read a half-torn-down decoder.
        stopTelemetryExporter()

        // Close any in-flight ConnectFlow interval. If the connection
        // never reached connectionEstablished, leaving the interval open
        // would show as a runaway-open span in Instruments. Closing here
        // with outcome=aborted is the universal cleanup for every stop
        // path (user quit, connection terminated, startConnection error).
        if let state = connectFlowState {
            OSSignposter.network.endInterval(
                "ConnectFlow", state, "outcome=aborted")
            connectFlowState = nil
        }

        // Teardown order: stop the backend (drains its threads), take down what
        // the user sees, shut audio, then release the bridge. Its refs
        // are weak, so the order is about being well-behaved, not UAF safety.

        // 0. Hide the overlay before closing; stop timers before their RTT reads
        // outlive the connection. Snapshot actor-owned UI refs for MainActor.run.
        let winForOverlay = self.window
        let inputForQuiesce = input
        await MainActor.run {
            self.statsOverlayTimer?.invalidate()
            self.statsOverlayTimer = nil
            self.frameWatchdogTimer?.invalidate()
            self.frameWatchdogTimer = nil
            self.presentWatchdogTimer?.invalidate()
            self.presentWatchdogTimer = nil
            self.stopPresentMetricTimer()
            winForOverlay?.statsOverlay.setVisible(false)
            // Key-ups go out while the uplink is still live; once not ready, a
            // quit chord's late modifier releases send nothing into a closed link.
            inputForQuiesce?.raiseAllHeldInputs(reason: "stream teardown")
            inputForQuiesce?.setReady(false)
        }

        // 1. Tell the backend to bring down the connection. Synchronous;
        //    blocks until receive/decode/control threads have exited. Safe to
        //    call even if a teardown is already in flight (the backend tracks
        //    its own state internally).
        backend.stopConnection()

        // 2. Close the window and release input before draining audio, so a dead link
        //    cannot hold a frozen full-screen frame and a hidden pointer.
        let dec = videoDecoder
        let win = window
        // Setup may have adopted input while the timer teardown was suspended.
        let inp = input
        await MainActor.run {
            inp?.detach()
            dec?.teardown()
            // Close the window last on the MainActor; close() awaits the
            // exit-fullscreen animation before orderOut'ing, then refocuses
            // the main Glimmer window for a clean handoff back to the app.
            win?.close()
        }

        // 3. The AVAudioEngine teardown. Step 1 already drained the audio
        //    receive thread, so no final sample can race it.
        audioDecoder.shutdown()

        // 4. Disconnect leaves the PC app running, including a late /launch success.
        let net = cleanupNetwork
        if let net {
            // shutdown() is a no-op now (the control channel is per-request) -
            // kept for symmetry with the rest of the teardown.
            await net.shutdown()
        }
        ownsHostSession = false
        hostSessionClientID = nil
        network = nil

        // Close after teardown so the session log records backend and audio teardown outcomes.
        SessionLogFileSink.stop()

        // 5. Release the bridge. The bridge held weak refs to everything so
        //    nil'ing our own field doesn't drop the retain - the
        //    passRetained(bridge) in start() did. Match it here.
        if StreamBridgeContext.current === self.bridge {
            StreamBridgeContext.current = nil
        }
        if let ptr = bridgePtr {
            Unmanaged<StreamBridgeContext>.fromOpaque(ptr).release()
        }
        bridgePtr = nil
        // finish() ends AppModel's `for await`, which is how it learns the stream is over, and turns
        // any late yield from a callback thread into a no-op. Clearing the field instead would race them.
        bridge?.eventContinuation?.finish()
        bridge = nil

        // 6. Release the keep-awake assertion taken in start(). Balanced 1:1
        //    with beginActivity; nil-guarded so a second stop() can't double-end.
        if let assertion = powerAssertion {
            ProcessInfo.processInfo.endActivity(assertion)
            powerAssertion = nil
        }

        input = nil
        window = nil
        videoDecoder = nil
        stopInProgress = false
    }

    /// A reconnect may have dropped its client before teardown.
    var cleanupNetwork: NetworkClient? {
        network ?? reconnectServer.map(makeNetwork)
    }

    public func interrupt() async {
        guard isStreaming else { return }
        backend.interruptConnection()  // was LiInterruptConnection()
        await stop()
    }

    // MARK: - Launch with busy recovery

    /// Resume only our requested app; destructive recovery always requires confirmation.
    func launchWithBusyRecovery(
        network: NetworkClient, appID: Int, config: StreamConfig, info: ServerInfo, deadline: Date
    ) async throws -> LaunchResponse {
        try checkAttempt(deadline: deadline)
        resumingHostApp = false
        resumeFailure = nil
        restoreOwnership(from: info)
        try await authorizeOccupancy(info, network: network, deadline: deadline)
        if info.currentGameID == appID, ownsHostSession, !takeoverAuthorized {
            resumingHostApp = true
            // Sunshine src/nvhttp.cpp: resume() calls make_launch_session(args), which reads
            // mode (width/height/fps) and hdrMode, then configure_display when no stream is active.
            do {
                return try await launchHost(network: network, appID: appID, config: config,
                                            deadline: deadline, resume: true)
            } catch {
                if error is CancellationError { throw error }
                Diag.notice("Resume /resume failed: \(error, privacy: .private)", "Stream")
                let failure = ResumeFailed(underlying: error)
                resumeFailure = failure
                throw failure
            }
        }
        if info.currentGameID != 0 || info.isBusy {
            // Owning a different app never authorizes quitting it.
            guard takeoverAuthorized else { throw TakeoverRequired(appID: info.currentGameID) }
            return try await cancelThenLaunch(network: network, appID: appID, config: config, deadline: deadline)
        }
        return try await launchHost(network: network, appID: appID, config: config, deadline: deadline)
    }

    private func restoreOwnership(from info: ServerInfo) {
        guard let server = reconnectServer else { return }
        RunningAppOwnership.reconcile(pc: server.uniqueId, appID: info.currentGameID)
        guard !ownsHostSession,
              let owner = RunningAppOwnership.load(pc: server.uniqueId),
              owner.appID == info.currentGameID else { return }
        ownsHostSession = true
        hostSessionClientID = owner.clientID
        hostSessionAppID = owner.appID
    }

    func authorizeOccupancy(_ info: ServerInfo, network: NetworkClient, deadline: Date) async throws {
        let client = await network.clientUniqueID
        try checkAttempt(deadline: deadline)
        let owner = ownsHostSession && info.currentGameID == hostSessionAppID ? hostSessionClientID : nil
        if StreamAttempt.requiresTakeover(
            occupied: info.currentGameID != 0 || info.isBusy,
            owner: owner, client: client, authorized: takeoverAuthorized) {
            ownsHostSession = false
            hostSessionClientID = nil
            throw TakeoverRequired(appID: info.currentGameID)
        }
    }

    private func launchHost(
        network: NetworkClient, appID: Int, config: StreamConfig, deadline: Date, resume: Bool = false
    ) async throws -> LaunchResponse {
        let client = await network.clientUniqueID
        try checkAttempt(deadline: deadline)
        let start = Date()
        defer { ConnectTimingTelemetry.shared.recordLaunchLeg(launchMs: Date().timeIntervalSince(start) * 1000) }
        let response = try await launchAndRecordOwnership(client: client, appID: appID) {
            if resume { return try await network.resume(config: config) }
            return try await network.launch(appID: appID, config: config)
        }
        try checkAttempt(deadline: deadline)
        return response
    }

    func launchAndRecordOwnership(
        client: String?, appID: Int, operation: @escaping @Sendable () async throws -> LaunchResponse
    ) async throws -> LaunchResponse {
        // A late success still belongs to this Mac, unless another launch superseded it.
        let key = launchPCKey
        let task = try await Self.launchMutations.launch(pc: key, client: client, appID: appID, operation: operation)
        ownsHostSession = true
        hostSessionClientID = client
        hostSessionAppID = appID
        pendingLaunch = task
        defer { if pendingLaunch == task { pendingLaunch = nil } }
        return try await consumeLaunch(task)
    }

    private func consumeLaunch(_ task: Task<LaunchResponse, Error>) async throws -> LaunchResponse {
        do {
            return try await task.value
        } catch {
            if pendingLaunch == task, !Self.retainsLaunchOwnership(after: error) {
                ownsHostSession = false
                hostSessionClientID = nil
            }
            throw error
        }
    }

    /// Explicit quits finish before a new launch on the same PC.
    static let launchMutations = HostLaunchMutations()

    private var launchPCKey: String { reconnectServer?.uniqueId ?? "" }

    nonisolated var terminationStopBoundSeconds: TimeInterval { TerminationGate.stopBoundSeconds }

    static func retainsLaunchOwnership(after error: Error) -> Bool {
        if case .hostRefused = error as? StreamError { return false }
        return true
    }

    private func cancelThenLaunch(
        network: NetworkClient, appID: Int, config: StreamConfig, deadline: Date
    ) async throws -> LaunchResponse {
        try checkAttempt(deadline: deadline)
        let start = Date()
        try await network.cancel()
        try checkAttempt(deadline: deadline)
        ConnectTimingTelemetry.shared.recordLaunchLeg(cancelMs: Date().timeIntervalSince(start) * 1000)
        try await waitForHostIdle(network: network, deadline: deadline)
        try checkAttempt(deadline: deadline)
        return try await launchHost(network: network, appID: appID, config: config, deadline: deadline)
    }

    private func waitForHostIdle(network: NetworkClient, deadline: Date) async throws {
        let start = Date()
        let idleDeadline = min(deadline, start.addingTimeInterval(5))
        var polls = 0
        defer {
            ConnectTimingTelemetry.shared.recordLaunchLeg(
                launchBusyWaitMs: Date().timeIntervalSince(start) * 1000, busyPollCount: polls)
        }
        while Date() < idleDeadline {
            try checkAttempt(deadline: deadline)
            try await Task.sleep(for: .milliseconds(250))
            try checkAttempt(deadline: deadline)
            polls += 1
            let info = try await network.fetchServerInfo()
            try checkAttempt(deadline: deadline)
            if info.currentGameID == 0, !info.isBusy { return }
            try await authorizeOccupancy(info, network: network, deadline: deadline)
        }
        try checkAttempt(deadline: deadline)
    }

    var isTearingDown: Bool { !isStreaming || stopInProgress }

    /// The launch under one wall-clock deadline; a stop() mid-launch cancels it.
    func launchWithDeadline(
        network: NetworkClient, appID: Int, config: StreamConfig, info: ServerInfo, deadline: Date? = nil
    ) async throws -> LaunchResponse {
        let end = deadline ?? Date().addingTimeInterval(Self.launchOverallDeadlineSeconds)
        await network.setRequestDeadline(end)
        try checkAttempt(deadline: end)
        let task = Task {
            try await StreamAttempt.run(until: end) {
                try await self.launchWithBusyRecovery(
                    network: network, appID: appID, config: config, info: info, deadline: end)
            }
        }
        launchTask = task
        defer { launchTask = nil }
        return try await withTaskCancellationHandler {
            do {
                let result = try await task.value
                try checkAttempt(deadline: end)
                return result
            } catch {
                if resumingHostApp, !(error is CancellationError) {
                    let failure = error as? ResumeFailed ?? ResumeFailed(underlying: error)
                    resumeFailure = failure
                    throw failure
                }
                throw error
            }
        } onCancel: {
            task.cancel()
        }
    }
}
