//
//  AudioDecoder+Engine.swift
//
//  The opus + AVAudioEngine LIFECYCLE: `initDecoderCore` (decoder create,
//  channel layout, graph wiring, engine start, session state reset), the
//  `shutdown()` teardown, and the mid-stream RECOVERY family that keeps playout
//  alive - the H3/H4 configuration-change hop, the bounded engine-restart retry
//  ladder, the exception-safe prime-edge start, and the playout-stall rebuild.
//  Split from AudioDecoder.swift - same idiom as the FramePacer split, to keep
//  that file under the length limit. They belong together: every one of them is
//  an AV-node call serialized on `stateLock`, and they share the same "no AV
//  calls from a completion handler" discipline.
//
//  Split cost (the ControllerForwarder.swift note, applied here): stored
//  properties cannot live in an extension, so the opus/engine core state stays
//  on `AudioDecoder` and is `internal` rather than `private` for the methods in
//  this file (and AudioDecoder+Decode.swift) to reach. See the property docs in
//  AudioDecoder.swift for the locking rationale each one carries.
//

import AVFoundation
import Foundation

extension AudioDecoder {

    // MARK: Lifecycle

    /// Shared opus + AVAudioEngine setup, called by the Swift-native path (the
    /// `NativeAudioSink` conformance). Takes plain values, no C types.
    func initDecoderCore(channelCount chCount: Int, sampleRate: Int32,
                         streams strms: Int32, coupledStreams coupled: Int32,
                         samplesPerFrame spf: Int, mapping map: [UInt8]) -> Int32 {
        stateLock.lock()
        defer { stateLock.unlock() }
        channelCount = chCount
        samplesPerFrame = spf
        streams = Int(strms)
        coupledStreams = Int(coupled)
        mapping = map

        // P1 AUDIO meter: capture the output sample rate (frames↔ms conversion) and
        // reset the playout accounting for this session. Under the small meter lock,
        // never on the per-packet path. The seed loads BEFORE the lock (UserDefaults
        // + route latch); seeding the target from per-host memory makes the cold
        // pre-roll build last session's learned depth, not re-pay 5-8 startup blips.
        let seed = Self.loadCushionSeed()
        // Per-host skew seed: start the resampler's integral at the persisted
        // converged clock offset so the session begins pre-corrected instead of
        // re-drifting into the first minutes' underruns (the ratchet feed).
        let skewSeedPpm = Self.loadResamplerSkewSeed(host: seed.host)
        if skewSeedPpm != 0 {
            Diag.notice("audio resampler skew seed: \(Int(skewSeedPpm.rounded()))ppm "
                + "from per-host memory - starts pre-converged", "Stream.Audio")
        }
        resetPlayoutStateForSession(seed: seed, sampleRate: sampleRate,
                                    skewSeedPpm: skewSeedPpm)
        announceCushionSeed(seed)
        // A/V-skew session edge: the skew store's pair-anchor + accumulator
        // reset here (one audio init per session IS the pair's session edge).
        AudioVideoSkewStore.shared.resetForNewSession()

        var err: Int32 = 0
        decoder = opus_multistream_decoder_create(
            sampleRate,
            Int32(channelCount),
            strms,
            coupled,
            mapping,
            &err
        )
        guard err == OPUS_OK, decoder != nil else {
            log.error("opus_multistream_decoder_create failed: \(err)")
            return -1
        }

        // Sunshine/GFE deliver opus channels in moonlight-common-c's canonical
        // order:  FL, FR, FC, LFE, BL, BR        (5.1)
        //         FL, FR, FC, LFE, BL, BR, SL, SR (7.1)
        // Apple's `kAudioChannelLayoutTag_AudioUnit_5_1` (= MPEG_5_1_A) is
        // L,R,C,LFE,Ls,Rs - that matches the 5.1 order exactly, so no remap.
        // Apple's `kAudioChannelLayoutTag_AudioUnit_7_1` (= MPEG_7_1_C) is
        // L,R,C,LFE,Ls,Rs,Rls,Rrs - channels 4-7 are *paired-swapped*
        // versus Sunshine. Build an explicit reorder table here; the alternative
        // (rewriting `mapping` like moonlight-qt's SLAudio renderer does)
        // bakes assumptions into the opus decoder we don't need.
        outputReorder = nil
        if channelCount == 8 {
            // src index → dst index   (src is Sunshine's order)
            //  0 FL  -> 0 L
            //  1 FR  -> 1 R
            //  2 FC  -> 2 C
            //  3 LFE -> 3 LFE
            //  4 BL  -> 6 Rls
            //  5 BR  -> 7 Rrs
            //  6 SL  -> 4 Ls
            //  7 SR  -> 5 Rs
            outputReorder = [0, 1, 2, 3, 6, 7, 4, 5]
        }

        guard let layout = AVAudioChannelLayout(layoutTag: layoutTag(forChannels: channelCount)) else {
            log.error("AVAudioChannelLayout init failed")
            return -1
        }
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                sampleRate: Double(sampleRate),
                                interleaved: false,
                                channelLayout: layout)
        inputFormat = fmt

        guard startEngineGraph(format: fmt) else { return -1 }
        // Engine-running mirror for the telemetry gauge, set under the meter lock
        // (read there by publishAudioState) - a plain Bool, no AVAudio call.
        audioMeterLock.lock(); engineRunning = engine.isRunning; audioMeterLock.unlock()
        // Baseline the output (hardware) format so the config-change handler can
        // tell a real route-format move from a benign notification.
        lastOutputFormat = engine.outputNode.outputFormat(forBus: 0)
        // Seed + track the audio OUTPUT route for the under-run breadcrumbs.
        // Installed only after the engine is up, so a failed init never leaves a
        // listener behind; `shutdown()` removes it.
        installAudioRouteListener()
        // H3: recover playout across a mid-stream output-device/format change
        // (BT/AirPods connect-disconnect, HDMI/DP unplug, USB-DAC removal, OS
        // sample-rate change), which STOPS the engine's outputNode. Installed
        // after the engine is up so a failed init never leaves an observer behind;
        // `shutdown()` removes it.
        installConfigChangeObserver()
        return 0
    }

    /// Reset the meter / cushion / watchdog state machine for a fresh session and
    /// adopt this session's seed. Caller is `initDecoderCore` with `stateLock`
    /// held; this takes `audioMeterLock` for the duration of the reset (never the
    /// other way round).
    private func resetPlayoutStateForSession(seed: CushionSeed, sampleRate: Int32,
                                             skewSeedPpm: Double) {
        let seedNowNanos = DispatchTime.now().uptimeNanoseconds
        // AV call BEFORE the meter lock (leaf-lock discipline, audit remainder
        // 2026-08-26): varispeed.rate is an AVAudio node property - writing it
        // under audioMeterLock inverted the documented ordering that keeps node
        // calls out of the lock the completion handlers take. Init-time and
        // stateLock-held, so the hazard was theoretical; the rule isn't.
        varispeed.rate = 1.0
        audioMeterLock.lock()
        meterSampleRate = Double(sampleRate)
        framesScheduled = 0; framesPlayed = 0
        driftAnchorNanos = 0; driftAnchorFramesPlayed = 0
        resamplerIntegralPpm = skewSeedPpm; resamplerEpsPpm = 0
        resamplerEverEngaged = false
        lastResamplerSkewSaveNanos = 0; lastSavedResamplerSkewPpm = .nan
        playoutStarted = false; playoutDrained = false; meterShutdown = false
        // FIX: clear the teardown latch on RE-init. A reconnect's stopConnection →
        // shutdown() set `isShutdown = true` and nothing reset it, so post-reconnect
        // every decoded frame was dropped by the decode guards (packets flow, playout
        // dead). Re-init under the lock is the honest "this decoder is live again" edge.
        if isShutdown { Diag.info("audio decoder re-init - isShutdown reset (reconnect)", "Stream.Audio") }
        isShutdown = false
        engineRunning = false
        // Cushion / pre-roll state for this session: start paused (no play() at
        // engine start), at the SEEDED adaptive target, re-prime count reset. (The
        // reset-on-read MIN-fill window lives in TelemetryCounters and is cleared by
        // its own resetForNewSession.) The quiet anchors start NOW: a seeded
        // (elevated) target must earn its first decay window.
        primed = false
        buffersSinceArm = 0
        playoutTargetMs = seed.targetMs
        learnedFloorMs = seed.floorMs
        cushionSeedKey = seed.key
        cushionHostLabel = seed.host
        cushionHadUnderrun = false
        cushionLinkResolved = seed.linkKnown
        cushionLinkResolveDeadlineNanos = seedNowNanos &+ Self.cushionLinkResolveWindowNanos
        // LINK-AWARE caps: seed from the resolved link; `resolveCushionLink`
        // refreshes them if the route lands after bring-up.
        effectiveCushionMaxMs = Self.cushionMaxMs(forLink: seed.link)
        effectiveOverrunCeilingMs = effectiveCushionMaxMs + Self.bufferOverrunCeilingSlackMs
        quietWindowMinFillMs = .infinity
        rePrimeCount = 0
        lastTrimNanos = 0; gateGraceUntilNanos = 0
        pendingResolveTopUp = false; floorLearnGateUntilNanos = 0
        nearMissLatched = false
        quietSinceNanos = seedNowNanos
        floorQuietSinceNanos = seedNowNanos
        rebuildIsReprime = false
        lastUnderrunNoticeNanos = 0; underrunNoticesSuppressed = 0
        // Playout-stall watchdog state (fresh session = no progress history yet).
        lastPlayoutProgressNanos = 0
        playoutStallPending = false
        stallRecoveryLastAttemptNanos = 0
        meterRecovering = false
        audioMeterLock.unlock()
    }

    /// Attach + wire playerNode → varispeed → mixer at the decode format and get
    /// the engine running. Returns false (after logging) when the engine refuses
    /// to start, so `initDecoderCore` can fail the init. Caller holds `stateLock`.
    private func startEngineGraph(format fmt: AVAudioFormat) -> Bool {
        // Idempotent on a reconnect re-init: a node already on this engine must not
        // be re-attached (AVAudio faults on a double-attach). `node.engine == nil`
        // is the "not attached" test.
        if playerNode.engine == nil { engine.attach(playerNode) }
        if varispeed.engine == nil { engine.attach(varispeed) }
        // playerNode → varispeed → mixer. The varispeed resamples the player's
        // output by `rate=1+ε` (driveResampler), pulling the player's buffers at
        // the consumption rate - so completion timing (framesPlayed) still tracks
        // real consumption and the input-frame fill/cushion math reads true (the
        // ε factor on the frames→ms convert is ppm-negligible).
        engine.connect(playerNode, to: varispeed, format: fmt)
        engine.connect(varispeed, to: engine.mainMixerNode, format: fmt)
        do {
            // Start the engine but DO NOT `play()` the player node yet. Playback is
            // deferred until a `playoutTargetMs` cushion of decoded audio is queued
            // (the pre-roll in `meterRegisterScheduleOrOverrun` / `maybePrime`),
            // so the player starts with headroom instead of on the under-run floor.
            // The node is scheduled-into while paused; `play()` then drains the
            // already-queued cushion gapless.
            // Only start when not already running (idempotent across a reconnect
            // re-init that left the engine up).
            if !engine.isRunning { try engine.start() }
        } catch {
            log.error("AVAudioEngine.start: \(error.localizedDescription)")
            Diag.error("audio engine start FAILED: \(error.localizedDescription)", "Stream.Audio")
            return false
        }
        return true
    }

    private func layoutTag(forChannels channels: Int) -> AudioChannelLayoutTag {
        switch channels {
        case 2: return kAudioChannelLayoutTag_Stereo
        case 6: return kAudioChannelLayoutTag_AudioUnit_5_1
        case 8: return kAudioChannelLayoutTag_AudioUnit_7_1
        default: return kAudioChannelLayoutTag_Stereo
        }
    }

    public func shutdown() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !isShutdown else { return }
        isShutdown = true
        // Quiesce the meter's EVIDENCE machinery BEFORE stopping the node:
        // stop() flushes a completion-handler burst for the standing cushion
        // (6-30 buffers), and un-gated its last completion minted a synthetic
        // under-run on EVERY session end - ratcheting the target +10ms, EWMA-
        // pulling the learned floor, and PERSISTING both per-host, so sub-10-min
        // sessions walked toward the 150ms cap across sessions (the disguised-
        // permanent-pin class). Gate details: `meterCompleteOnePlayout`.
        audioMeterLock.lock()
        meterShutdown = true
        engineRunning = false   // gauge mirror; a Bool, not an AVAudio call
        audioMeterLock.unlock()
        playerNode.stop()
        engine.stop()
        removeAudioRouteListener()
        removeConfigChangeObserver()
        if let decoderPtr = decoder {
            opus_multistream_decoder_destroy(decoderPtr)
            decoder = nil
        }
        // No global to clear here - the StreamBridgeContext holds a weak
        // ref to us; when StreamSession drops its strong reference the bridge
        // sees nil at the next callback (or the bridge itself is released
        // first, which short-circuits earlier).
    }

    // MARK: - H3/H4 mid-stream audio-config recovery
    //
    // On a mid-stream output-device/format change (BT/AirPods connect-disconnect,
    // HDMI/DP unplug, USB-DAC removal, OS sample-rate change) AVAudioEngine STOPS
    // its outputNode and posts `AVAudioEngineConfigurationChange` - so without
    // recovery audio goes silent for the rest of the session. The route listener
    // only swaps a cached string; this is the actual recovery hop.
    //
    // DEADLOCK SAFETY: this fires on a NOTIFICATION, not a player-node completion
    // handler, so re-arming node properties here is safe - the historical freeze
    // came from touching AVAudio node props INSIDE a completion handler (which
    // holds the messenger lock and deadlocked teardown's `playerNode.stop()`).
    // We serialize on the SAME `stateLock` the decode + shutdown paths use, and
    // make ZERO node-prop changes from any completion path. `playerNode.stop()`
    // here flushes the queued buffers' completions, but those run
    // `meterCompleteOnePlayout`, which makes no AV calls (only `audioMeterLock`).

    /// Register the `AVAudioEngineConfigurationChange` observer. Called once from
    /// `initDecoderCore` with `stateLock` held (after the engine is up);
    /// idempotent via the token. The handler runs off a utility queue so the
    /// notification thread never blocks on `stateLock`.
    func installConfigChangeObserver() {
        guard configChangeObserver == nil else { return }
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.routeListenerQueue.async { self.handleEngineConfigurationChange() }
        }
    }

    /// Remove the config-change observer. Called from `shutdown()` with
    /// `stateLock` held; safe when never installed.
    func removeConfigChangeObserver() {
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
    }

    /// Re-resolve the output format, reconnect `varispeed -> mainMixer` if it
    /// moved, restart the engine if it stopped, and re-arm the pre-roll so the
    /// cushion rebuilds. On the `stateLock`-serialized path (never a completion
    /// handler). H4: re-samples `engine.isRunning` into the gauge mirror here too.
    /// Schedule a bounded, backed-off retry of the engine restart on the route
    /// queue. Called under stateLock from the config-change catch, so a transient
    /// device-not-ready throw on an AirPods/HDMI/DAC handoff self-heals.
    private func scheduleEngineRestartRetry() {
        guard engineRestartRetries < Self.maxEngineRestartRetries else {
            Diag.error("audio engine restart gave up after \(engineRestartRetries) retries", "Stream.Audio")
            return
        }
        engineRestartRetries += 1
        let attempt = engineRestartRetries
        routeListenerQueue.asyncAfter(deadline: .now() + 0.3 * Double(attempt)) { [weak self] in
            self?.retryEngineStart(attempt: attempt)
        }
    }

    private func retryEngineStart(attempt: Int) {
        stateLock.lock(); defer { stateLock.unlock() }
        guard !isShutdown, !engine.isRunning, inputFormat != nil else { return }
        do {
            try engine.start()
            engineRestartRetries = 0
            Diag.notice("audio engine restart retry \(attempt) succeeded", "Stream.Audio")
        } catch {
            Diag.error("audio engine restart retry \(attempt) failed: \(error.localizedDescription)", "Stream.Audio")
            scheduleEngineRestartRetry()
        }
    }

    /// PLAYOUT-STALL RECOVERY (the 2026-08-12 overnight wedge; detection in
    /// AudioDecoder+Meter.swift). Rebuild the output path after the meter
    /// latched a stall: scheduled audio consumed ZERO frames past the threshold
    /// while every arrival dropped at the backlog gates. Caller holds
    /// `stateLock` (the decode path - the one place AV calls are serialized
    /// against `shutdown()`, the same discipline as
    /// `handleEngineConfigurationChange`). stop() fires the queued buffers'
    /// completions on the meter path (no AV calls there); `meterRecovering`
    /// gates their under-run EVIDENCE, and the completions reconcile
    /// `framesPlayed` so the next schedule takes the (re)arm edge - drift
    /// re-anchor, gate grace, cushion rebuild - and `maybePrime`'s cold-start
    /// pre-roll re-issues `play()`.
    /// Start playback at a prime edge, SAFELY (the 2026-08-17 post-wake crash).
    /// System sleep tears the audio hardware down mid-stream and stops the
    /// engine; the resume edge's re-prime then called `playerNode.play()` 9s
    /// after wake, which raises an NSException Swift cannot catch - process
    /// dead on the audio receive thread. Two layers here: ensure the engine is
    /// running first (post-wake it usually just needs a start(); failure arms
    /// the existing bounded retry ladder), then run play() under the ObjC
    /// exception shim so even an engine that LIES about isRunning (device
    /// mid-transition) degrades to a false return instead of an abort.
    /// Returns false when playback could not start - the caller must leave the
    /// state machine UN-primed so the next packet retries the edge; packets
    /// keep scheduling meanwhile, so recovery is one successful start away.
    /// Caller is the decode path with `stateLock` held (AV calls serialized
    /// against `shutdown()`), never inside `audioMeterLock`.
    func startPlayoutAtPrimeEdge() -> Bool {
        if !engine.isRunning {
            // The start itself goes under the shim too: `engine.start()`
            // reports missing-hardware failures as a thrown NSError, but some
            // states (an incomplete graph, a device mid-teardown) RAISE an
            // NSException instead - the test suite's empty-graph decoder
            // proved that path aborts without the guard.
            var startError: Error?
            let noRaise = gl_objc_try {
                do { try self.engine.start() } catch { startError = error }
            }
            guard noRaise, startError == nil, engine.isRunning else {
                Diag.error("audio engine start at prime edge FAILED "
                    + "(\(startError.map { $0.localizedDescription } ?? "NSException")) "
                    + "- staying un-primed, retry armed", "Stream.Audio")
                scheduleEngineRestartRetry()
                return false
            }
            engineRestartRetries = 0
            Diag.notice("audio engine restarted at the prime edge "
                + "(stopped underneath us - system sleep?)", "Stream.Audio")
        }
        guard gl_objc_try({ self.playerNode.play() }) else {
            Diag.error("audio playerNode.play() threw at the prime edge (device "
                + "mid-transition?) - staying un-primed, will retry per packet",
                "Stream.Audio")
            return false
        }
        return true
    }

    func recoverIfPlayoutStalled() {
        let now = DispatchTime.now().uptimeNanoseconds
        audioMeterLock.lock()
        guard playoutStallPending else { audioMeterLock.unlock(); return }
        playoutStallPending = false
        stallRecoveryLastAttemptNanos = now
        meterRecovering = true
        audioMeterLock.unlock()
        guard !isShutdown else { return }
        TelemetryCounters.shared.audioStallRecoveryTotal.increment()
        Diag.error("audio playout STALLED: scheduled audio unconsumed ≥3s with "
            + "every arrival dropped at the backlog gates (output device "
            + "slept/vanished?) - rebuilding: node stop → engine ensure-running "
            + "→ re-prime; route \(audioRouteCache)", "Stream.Audio")
        playerNode.stop()
        if !engine.isRunning {
            do {
                try engine.start()
                engineRestartRetries = 0
            } catch {
                Diag.error("audio engine restart in stall recovery FAILED: "
                    + "\(error.localizedDescription)", "Stream.Audio")
                scheduleEngineRestartRetry()
            }
        }
        let nowRunning = engine.isRunning
        audioMeterLock.lock()
        engineRunning = nowRunning
        // Re-arm the pre-roll state machine (the H3/H4 idiom). `playoutStarted =
        // false` makes the next arm edge a COLD start - correct, the node was
        // just stopped, so the paused pre-roll + `play()` at target is exactly
        // the rebuild it needs.
        primed = false
        playoutStarted = false
        playoutDrained = false
        buffersSinceArm = 0
        audioMeterLock.unlock()
    }

    private func handleEngineConfigurationChange() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !isShutdown, let fmt = inputFormat else { return }
        let newOutputFormat = engine.outputNode.outputFormat(forBus: 0)
        let formatMoved = lastOutputFormat.map { $0.sampleRate != newOutputFormat.sampleRate
            || $0.channelCount != newOutputFormat.channelCount } ?? true
        lastOutputFormat = newOutputFormat
        let wasRunning = engine.isRunning
        if formatMoved {
            // The output route's format changed: stop the player + reconnect the
            // graph at our (unchanged) decode format - the mixer/output handle SRC
            // to the new hardware rate. stop() here fires queued completions on the
            // meter path (no AV calls), and we hold stateLock so no decode races.
            //
            // EVIDENCE GATE (audit remainder, 2026-08-26): that completion burst
            // is the SAME one shutdown() and the stall recovery fire - and
            // un-gated, its last completion minted a SYNTHETIC under-run on
            // every mid-stream output-device change (AirPods connect/disconnect,
            // HDMI unplug, DAC removal): target ratcheted +10ms, floor
            // EWMA-pulled, both PERSISTED per host - audio latency quietly
            // crept across sessions for anyone who switches audio devices (the
            // disguised-permanent-pin class, in the one stop() this file had
            // left un-gated). Raise the same `meterRecovering` latch the stall
            // recovery uses; the re-arm below forces the next schedule's arm
            // edge, which clears it.
            audioMeterLock.lock()
            meterRecovering = true
            audioMeterLock.unlock()
            playerNode.stop()
            engine.connect(varispeed, to: engine.mainMixerNode, format: fmt)
        }
        if !engine.isRunning {
            do {
                try engine.start()
                engineRestartRetries = 0
            } catch {
                Diag.error("audio engine restart after config change FAILED: "
                    + "\(error.localizedDescription)", "Stream.Audio")
                scheduleEngineRestartRetry()
            }
        }
        // H4: re-sample the engine-running gauge here (the same hop), and RE-ARM
        // the pre-roll so the cushion rebuilds from the restart rather than the
        // player resuming on the under-run floor. A plain Bool + state-machine
        // resets under the meter lock - no AV call.
        let nowRunning = engine.isRunning
        audioMeterLock.lock()
        engineRunning = nowRunning
        if formatMoved || (!wasRunning && nowRunning) {
            primed = false
            playoutStarted = false
            playoutDrained = false
            buffersSinceArm = 0
        }
        audioMeterLock.unlock()
        Diag.notice("audio engine config change handled "
            + "(format \(formatMoved ? "moved" : "same"), running \(nowRunning))", "Stream.Audio")
    }
}
