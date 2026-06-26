//
//  StreamSession+Lifecycle.swift
//
//  Session teardown (stop/interrupt) and the launch-with-busy-recovery retry.
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
        // Reentrancy guard. stop() can be triggered from multiple paths:
        //   - the user's quit hotkey (InputForwarder.onQuitHotkey)
        //   - the connectionTerminated callback after the backend stops
        //   - the AsyncStream.onTermination handler when the consumer drops
        //   - startConnection's error path in start()
        // Any two of those can land back-to-back. We want exactly one
        // teardown to run; subsequent callers should observe a no-op.
        guard isStreaming, !stopInProgress else { return }
        stopInProgress = true
        isStreaming = false

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
        // session. The UI side (MoonlightManager's teardown cleanup)
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

        // Teardown order - load-bearing.
        //
        // The bridge holds *weak* references to every subsystem, so a
        // callback fired against a freed weak ref no-ops; ordering is
        // about "well-behaved" rather than UAF safety. We still drain the
        // backend's receive threads before dropping the AVAudio engine and the
        // AVSampleBufferDisplayLayer:
        //
        //   1. backend.stopConnection() - synchronous; blocks until the
        //      receive/decode/control threads have exited. After this
        //      returns no further callbacks can fire.
        //   2. network.cancel() - tell the host the session is over so
        //      the next /launch isn't blocked by an orphan session
        //      record.
        //   3. MainActor teardowns: input.detach(), videoDecoder.teardown(),
        //      window.close().
        //   4. audioDecoder.shutdown().
        //   5. Bridge release: Unmanaged.fromOpaque(...).release(). After
        //      everything above so a late callback (impossible after step
        //      1, cheap insurance) can't dereference a freed bridge.

        // 0. Stop the stats-overlay timer FIRST and hide the overlay layer
        //    so it doesn't linger visually while teardown runs (without
        //    this the user sees overlay numbers sitting on screen during
        //    the window-close beat). The timer's RTT-estimate read is also
        //    only safe while the connection is up.
        //
        // Capture `window` into a local so the MainActor.run closure
        // doesn't reach into the actor's isolated state - Swift 6 strict
        // concurrency rejects `self.window` from a non-actor closure even
        // when the closure hops to MainActor.
        let winForOverlay = self.window
        await MainActor.run {
            self.statsOverlayTimer?.invalidate()
            self.statsOverlayTimer = nil
            self.frameWatchdogTimer?.invalidate()
            self.frameWatchdogTimer = nil
            self.presentWatchdogTimer?.invalidate()
            self.presentWatchdogTimer = nil
            self.presentMetricTimer?.invalidate()
            self.presentMetricTimer = nil
            winForOverlay?.statsOverlay.setVisible(false)
        }

        // 1. Tell the backend to bring down the connection. Synchronous;
        //    blocks until receive/decode/control threads have exited. Safe to
        //    call even if a teardown is already in flight (the backend tracks
        //    its own state internally).
        backend.stopConnection()

        // 2. Tell the host the session is over so the next /launch isn't
        //    blocked by an orphan session record. Best-effort; the host can
        //    be unreachable here if the network just dropped.
        if let net = network {
            try? await net.cancel()
            // shutdown() is a no-op now (the control channel is per-request) -
            // kept for symmetry with the rest of the teardown.
            await net.shutdown()
        }
        network = nil

        // 3. MainActor-bound teardowns. Capture references first so we don't
        //    hold the actor across the hop.
        let dec = videoDecoder
        let inp = input
        let win = window
        await MainActor.run {
            inp?.detach()
            dec?.teardown()
            // Close the window last on the MainActor; close() awaits the
            // exit-fullscreen animation before orderOut'ing, then refocuses
            // the main Glimmer window for a clean handoff back to the app.
            win?.close()
        }

        // 4. Shut down audio after the connection is down so we don't
        //    race a final decodeAndPlaySample callback against the engine
        //    being torn down. (Strictly, step 1 already drained the audio
        //    worker thread; this is the AVAudioEngine teardown.)
        audioDecoder.shutdown()

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
        // Finish the event stream BEFORE we drop the bridge - once
        // bridge.eventContinuation goes nil, any final yields from C-thread
        // callbacks become no-ops. finish() signals end-of-stream to the
        // consumer's `for await` loop, which is how MoonlightManager learns
        // a stream is over.
        bridge?.eventContinuation?.finish()
        bridge?.eventContinuation = nil
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

    public func interrupt() async {
        guard isStreaming else { return }
        backend.interruptConnection()  // was LiInterruptConnection()
        await stop()
    }

    // MARK: - Launch with busy recovery
    //
    // Always renegotiate via `/cancel + /launch` on a user-initiated Stream
    // click. Calling `/resume` on `currentgame == ourAppID` preserves the
    // host-side STREAM_CONFIGURATION (resolution, FPS, HDR mode, codec
    // set) - which breaks the multi-device flow: start a 4K@240 stream
    // from the desktop, walk to the laptop, hit Stream → host /resumes
    // 4K@240, ignoring the 1920x1200@120 the laptop requested.
    //
    // If the host was idle, `/cancel` is a no-op. If it had a stale
    // session of ours, `/cancel` clears it. One-session-at-a-time is a
    // host-side constraint. A future "Resume Game" affordance would need
    // its own code path that explicitly calls /resume.
    func launchWithBusyRecovery(
        network: NetworkClient,
        appID: Int,
        config: StreamConfig,
        hintCurrentGame: Int
    ) async throws -> LaunchResponse {

        func tryLaunch() async throws -> LaunchResponse {
            log.info("→ /launch (appID=\(appID))")
            // Telemetry: stamp the /launch leg duration (launch sub-leg).
            let t0 = Date().timeIntervalSinceReferenceDate
            defer {
                ConnectTimingTelemetry.shared.recordLaunchLeg(
                    launchMs: (Date().timeIntervalSinceReferenceDate - t0) * 1000.0)
            }
            return try await network.launch(appID: appID, config: config)
        }

        // Wait for the host's `currentgame` to drop to 0, meaning Sunshine
        // has actually torn down the session - INCLUDING running the app's
        // Undo command (e.g. QRes.exe /X:3840 /Y:2160 /R:240 on Windows
        // hosts that swap display resolution per stream). If we just /cancel
        // and immediately /launch, the host can race Undo against Do: the
        // Do command sets the requested resolution, then Undo finishes and
        // resets to its default, last-writer-wins → user stuck at the host's
        // default resolution. Polling /serverinfo until the Undo completes
        // means the Do command from our subsequent /launch runs against a
        // settled state and wins.
        func waitForHostIdle(maxWait: TimeInterval) async {
            // Telemetry: time the whole busy-poll + count its /serverinfo polls so
            // the up-to-5s wait is attributable (launch_busy_wait_ms / _poll_count).
            let waitStart = Date()
            var polls = 0
            let deadline = waitStart.addingTimeInterval(maxWait)
            defer {
                ConnectTimingTelemetry.shared.recordLaunchLeg(
                    launchBusyWaitMs: Date().timeIntervalSince(waitStart) * 1000.0,
                    busyPollCount: polls)
            }
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 250_000_000)
                polls += 1
                if let info = try? await network.fetchServerInfo(),
                   info.currentGameID == 0 {
                    log.info("Host idle - Undo command completed")
                    return
                }
            }
            log.info("Host idle wait timed out after \(maxWait)s; proceeding with /launch anyway")
        }

        func tryCancelThenLaunch() async throws -> LaunchResponse {
            log.info("→ /cancel then /launch (forced renegotiation)")
            // Telemetry: stamp the /cancel leg duration (launch sub-leg).
            let cancelStart = Date()
            try? await network.cancel()
            ConnectTimingTelemetry.shared.recordLaunchLeg(
                cancelMs: Date().timeIntervalSince(cancelStart) * 1000.0)
            // Sunshine's Undo command on Windows hosts can take 1-3s
            // (QRes.exe is synchronous; some user configs include a sleep
            // for display-driver settle time). 5s ceiling is generous but
            // bounded - we'd rather wait than land on the wrong resolution.
            await waitForHostIdle(maxWait: 5)
            return try await network.launch(appID: appID, config: config)
        }

        // Primary: idle host → /launch directly (no point cancelling nothing).
        // Anything else → /cancel + /launch to force a fresh session config.
        do {
            if hintCurrentGame == 0 {
                return try await tryLaunch()
            } else {
                return try await tryCancelThenLaunch()
            }
        } catch let first as StreamError {
            log.error("primary launch path failed: \(String(describing: first), privacy: .public)")
            // M6: a stop()/cancelConnect() can land during the primary leg or the
            // host-idle poll. The actor sweeps it in at our awaits; re-check here
            // so the recovery leg (another ~5s poll + 20s /launch) doesn't stack on
            // a session the user already cancelled - rethrow the first error and
            // let start()'s teardown win instead.
            guard isStreaming, !stopInProgress else { throw first }
            // Recovery: race between hint and actual host state. One more
            // cancel + launch covers the "we thought idle but host had an
            // orphan" and the "cancel raced" cases. We deliberately do NOT
            // fall back to /resume here - that's the bug we're closing.
            if let r = try? await tryCancelThenLaunch() { return r }
            throw first
        }
    }

    /// True once a teardown has begun - either `stop()` flipped the latch or the
    /// session is no longer streaming. The launch-deadline watcher polls this so a
    /// stop()/cancelConnect() landing mid-launch bounces back without waiting out
    /// the non-cancellable HTTP leg. Actor-isolated so the read is race-free.
    var isTearingDown: Bool { !isStreaming || stopInProgress }

    /// M6: run `launchWithBusyRecovery` under an overall wall-clock deadline.
    ///
    /// ControlTransport's HTTP leg is a blocking socket that isn't cancellation-
    /// aware (it only unwinds on its own ~20s SO_RCVTIMEO), so we CANNOT rely on
    /// structurally awaiting the launch - a task-group child or `Task.result`
    /// await would pin us until that socket timed out, defeating the deadline.
    /// Instead a first-writer-wins box collects whichever of {launch finished,
    /// deadline/stop tripped} lands first; the read completes the instant either
    /// writer fires, so on a timeout/cancel we return PROMPTLY and leave the
    /// detached launch (now cancelled) to die on its own socket - rather than
    /// stranding the user at "Connecting..." for ~55-65s. The timeout surfaces as
    /// `.launchFailed` with honest copy.
    func launchWithDeadline(
        network: NetworkClient,
        appID: Int,
        config: StreamConfig,
        hintCurrentGame: Int
    ) async throws -> LaunchResponse {
        let deadline = Self.launchOverallDeadlineSeconds
        let box = FirstResultBox<LaunchResponse>()
        let launchTask = Task { [self] in
            do {
                let r = try await launchWithBusyRecovery(
                    network: network, appID: appID, config: config,
                    hintCurrentGame: hintCurrentGame)
                await box.offer(.success(r))
            } catch {
                await box.offer(.failure(error))
            }
        }
        // Watcher: trips on the wall-clock deadline OR a stop()/cancelConnect()
        // landing mid-launch (the blocking HTTP leg can't be force-aborted, so
        // without this the user would wait out the full deadline). Polls in 250ms.
        let watcher = Task { [self] in
            let end = Date().addingTimeInterval(deadline)
            while Date() < end {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if Task.isCancelled { return }
                if await self.isTearingDown {
                    await box.offer(.failure(StreamError.launchFailed("Launch cancelled.")))
                    return
                }
            }
            await box.offer(.failure(StreamError.launchFailed(
                "Host didn't respond within \(Int(deadline))s - giving up.")))
        }
        // Completes as soon as EITHER writer offers; the loser's later offer is
        // dropped by the box. Don't await the detached tasks structurally.
        let outcome = await box.value
        watcher.cancel()
        // On loss (timeout/cancel won), cancel the launch - best-effort; it dies
        // on its socket timeout and its late box.offer is a no-op.
        if case .failure = outcome { launchTask.cancel() }
        return try outcome.get()
    }
}

/// First-writer-wins async box: the first `offer` latches the value and resumes
/// the (single) pending `value` read; later offers are dropped. Used by M6 to
/// race a non-cancellable launch against a deadline/stop watcher and return the
/// instant either lands. Actor-isolated for race-free latching.
private actor FirstResultBox<T: Sendable> {
    private var result: Result<T, Error>?
    private var waiter: CheckedContinuation<Result<T, Error>, Never>?

    func offer(_ value: Result<T, Error>) {
        guard result == nil else { return }
        result = value
        if let waiter { self.waiter = nil; waiter.resume(returning: value) }
    }

    var value: Result<T, Error> {
        get async {
            if let result { return result }
            return await withCheckedContinuation { cont in waiter = cont }
        }
    }
}
