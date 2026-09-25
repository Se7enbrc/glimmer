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
        if let decoder { opus_multistream_decoder_destroy(decoder) }
        decoder = nil
        pendingFecGap = false
        engineRestartGeneration &+= 1
        engineRestartRetries = 0
        primeEdgeRetryAtNanos = 0
        primeEdgeFailureStreak = false
        var initialized = false
        defer {
            if !initialized, let decoder {
                opus_multistream_decoder_destroy(decoder)
                self.decoder = nil
            }
        }
        channelCount = chCount
        samplesPerFrame = spf
        streams = Int(strms)
        coupledStreams = Int(coupled)
        mapping = map

        let route = preparePlayoutForSession(sampleRate: sampleRate)

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

        guard let fmt = prepareInputFormat(sampleRate: sampleRate) else { return -1 }
        guard startEngineGraph(format: fmt) else { return -1 }
        // Engine-running mirror for the telemetry gauge, set under the meter lock
        // (read there by publishAudioState) - a plain Bool, no AVAudio call.
        let running = engine.isRunning
        audioMeterLock.lock(); engineRunning = running; audioMeterLock.unlock()
        // Baseline the output (hardware) format so the config-change handler can
        // tell a real route-format move from a benign notification.
        lastOutputFormat = engine.outputNode.outputFormat(forBus: 0)
        // Track the output route only after graph setup succeeds, so a failed
        // init leaves no listener behind; shutdown removes it.
        installAudioRouteListener(initial: route)
        // Observe device changes even if the first start failed, so a route
        // becoming ready can recover audio; shutdown removes the observer.
        installConfigChangeObserver()
        initialized = true
        return 0
    }

    private func preparePlayoutForSession(sampleRate: Int32) -> AudioRoute {
        // Load memory before the meter lock so cold pre-roll starts at the PC's
        // learned depth instead of paying for startup underruns again.
        let seed = Self.loadCushionSeed()
        // Per-host+device skew seed: start the resampler's integral at the persisted
        // offset between the PC's clock and THIS output device's clock, so the
        // session begins pre-corrected instead of re-drifting into underruns.
        let route = Self.sampleAudioRoute()
        let skewKey = Self.resamplerSkewKey(host: seed.host, deviceUID: route.uid)
        let skewSeedPpm = Self.loadResamplerSkewSeed(key: skewKey)
        if skewSeedPpm != 0 {
            Diag.notice("audio resampler skew seed: \(Int(skewSeedPpm.rounded()))ppm "
                + "from per-device memory - starts pre-converged", "Stream.Audio")
        }
        resetPlayoutStateForSession(seed: seed, sampleRate: sampleRate,
                                    skewSeedPpm: skewSeedPpm, skewKey: skewKey)
        announceCushionSeed(seed)
        // A/V-skew session edge: the skew store's pair-anchor + accumulator
        // reset here (one audio init per session IS the pair's session edge).
        AudioVideoSkewStore.shared.resetForNewSession()
        return route
    }

    private func prepareInputFormat(sampleRate: Int32) -> AVAudioFormat? {
        // Sunshine's 5.1 order matches Apple's layout. In 7.1, rear and side
        // pairs swap places; reorder output without changing the opus mapping.
        outputReorder = channelCount == 8 ? [0, 1, 2, 3, 6, 7, 4, 5] : nil
        guard let layout = AVAudioChannelLayout(layoutTag: layoutTag(forChannels: channelCount)) else {
            log.error("AVAudioChannelLayout init failed")
            return nil
        }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: Double(sampleRate),
                                   interleaved: false,
                                   channelLayout: layout)
        inputFormat = format
        return format
    }

    /// Reset the meter / cushion / watchdog state machine for a fresh session and
    /// adopt this session's seed. Caller is `initDecoderCore` with `stateLock`
    /// held; this takes `audioMeterLock` for the duration of the reset (never the
    /// other way round).
    private func resetPlayoutStateForSession(seed: CushionSeed, sampleRate: Int32,
                                             skewSeedPpm: Double, skewKey: String) {
        let seedNowNanos = DispatchTime.now().uptimeNanoseconds
        lastArrivalGapNanos.store(0)
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
        resamplerSkewMemoryKey = skewKey
        resamplerQuietIntegralSumPpm = 0; resamplerQuietTicks = 0
        resamplerSetpointMs = 0; resamplerSetpointMovedNanos = 0
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
        lastCushionGrowNanos = 0
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
    /// the engine running. A connect exception fails init; a transient start
    /// failure keeps receive alive for recovery. Caller holds `stateLock`.
    private func startEngineGraph(format fmt: AVAudioFormat) -> Bool {
        // Idempotent on a reconnect re-init: a node already on this engine must not
        // be re-attached (AVAudio faults on a double-attach). `node.engine == nil`
        // is the "not attached" test.
        if playerNode.engine == nil { engine.attach(playerNode) }
        if varispeed.engine == nil { engine.attach(varispeed) }
        // Varispeed pulls player buffers at rate=1+ε, so completions still track
        // real consumption and cushion accounting stays in input frames.
        // The ε correction to frames→ms is ppm-negligible.
        guard gl_objc_try({
            self.engine.connect(self.playerNode, to: self.varispeed, format: fmt)
            self.engine.connect(self.varispeed, to: self.engine.mainMixerNode, format: fmt)
        }) else {
            Diag.error("audio graph connect raised (device mid-transition?) - init failed", "Stream.Audio")
            return false
        }
        // Start the engine but don't `play()` yet: playback waits for a cushion of
        // queued audio (the pre-roll in `maybePrime`), so it starts with headroom.
        // Only start when not already running (a reconnect re-init can leave it up).
        if engine.isRunning {
            applyOutputMute()
        } else if let failure = startEngineSafely() {
            log.error("AVAudioEngine.start: \(failure, privacy: .private)")
            Diag.error("audio engine start FAILED: \(failure, privacy: .private)", "Stream.Audio")
            scheduleEngineRestartRetry()
        }
        return true
    }

    /// `engine.start()` under the ObjC exception shim: some states (an incomplete
    /// graph, a device mid-teardown) RAISE instead of throwing. Returns nil once
    /// running (stream mute re-applied), else what failed. Caller holds `stateLock`.
    func startEngineSafely() -> String? {
        var startError: Error?
        let noRaise = gl_objc_try {
            do { try self.engine.start() } catch { startError = error }
        }
        if let startError { return startError.localizedDescription }
        guard noRaise else { return "NSException" }
        applyOutputMute()
        let running = engine.isRunning
        audioMeterLock.lock(); engineRunning = running; audioMeterLock.unlock()
        return nil
    }

    /// Silence (or restore) only this stream at the engine's main mixer; other
    /// apps and the system volume are untouched. Caller holds `stateLock`.
    func applyOutputMute() {
        engine.mainMixerNode.outputVolume = outputMuted ? 0 : 1
    }

    /// Mute this stream on the Mac while the PC plays its sound. The engine keeps
    /// running, so the audio path and its telemetry are identical either way.
    /// Safe before audio starts: the value is applied when the engine comes up.
    public func setOutputMuted(_ muted: Bool) {
        stateLock.lock()
        defer { stateLock.unlock() }
        outputMuted = muted
        if inputFormat != nil { applyOutputMute() }
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
        engineRestartGeneration &+= 1
        pendingFecGap = false
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

    /// Observe after graph setup, even if start failed; caller holds stateLock.
    /// The token makes installation idempotent, and the utility queue keeps
    /// the notification thread from blocking on stateLock.
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

    /// Retry transient device failures on the route queue with bounded backoff.
    /// Caller holds stateLock; prime edges and stall recovery continue after
    /// this ladder is exhausted so a returning device can still recover.
    private func scheduleEngineRestartRetry() {
        guard engineRestartRetries < Self.maxEngineRestartRetries else { return }
        engineRestartRetries += 1
        let attempt = engineRestartRetries
        let generation = engineRestartGeneration
        routeListenerQueue.asyncAfter(deadline: .now() + 0.3 * Double(attempt)) { [weak self] in
            self?.retryEngineStart(attempt: attempt, generation: generation)
        }
    }

    func retryEngineStart(attempt: Int, generation: UInt64) {
        stateLock.lock(); defer { stateLock.unlock() }
        guard generation == engineRestartGeneration,
              !isShutdown, !engine.isRunning, inputFormat != nil else { return }
        if let failure = startEngineSafely() {
            Diag.error("audio engine restart retry \(attempt) failed: \(failure, privacy: .private)", "Stream.Audio")
            lastOutputFormat = nil
            if attempt == Self.maxEngineRestartRetries {
                Diag.error("audio engine restart gave up after \(attempt) retries", "Stream.Audio")
            }
            scheduleEngineRestartRetry()
        } else {
            engineRestartRetries = 0
            Diag.notice("audio engine restart retry \(attempt) succeeded", "Stream.Audio")
        }
    }

    /// Sleep can stop the engine or make play() raise despite isRunning.
    /// Caller holds stateLock, never audioMeterLock, across AV calls.
    /// Failed edges remain un-primed and retry after 100 ms.
    func startPlayoutAtPrimeEdge() -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now >= primeEdgeRetryAtNanos else { return false }
        if !engine.isRunning {
            // Guarded start: the test suite's empty-graph decoder proved an
            // unguarded start() raises and aborts here.
            let failure = startEngineSafely()
            guard failure == nil, engine.isRunning else {
                primeEdgeRetryAtNanos = now &+ 100_000_000
                if !primeEdgeFailureStreak {
                    primeEdgeFailureStreak = true
                    Diag.error("audio engine start at prime edge FAILED "
                        + "(\(failure ?? "engine not running", privacy: .private)) "
                        + "- staying un-primed, retry armed", "Stream.Audio")
                    scheduleEngineRestartRetry()
                }
                return false
            }
            engineRestartRetries = 0
            Diag.notice("audio engine restarted at the prime edge "
                + "(stopped underneath us - system sleep?)", "Stream.Audio")
        }
        guard gl_objc_try({ self.playerNode.play() }) else {
            primeEdgeRetryAtNanos = now &+ 100_000_000
            if !primeEdgeFailureStreak {
                primeEdgeFailureStreak = true
                Diag.error("audio playerNode.play() threw at the prime edge (device "
                    + "mid-transition?) - staying un-primed, will retry after spacing",
                    "Stream.Audio")
            }
            return false
        }
        primeEdgeFailureStreak = false
        primeEdgeRetryAtNanos = 0
        return true
    }

    // Stop flushes completions: meterRecovering gates synthetic underruns while
    // they reconcile framesPlayed. Re-arming forces a fresh cushion and play().
    func recoverIfPlayoutStalled() {
        let now = DispatchTime.now().uptimeNanoseconds
        audioMeterLock.lock()
        guard playoutStallPending else { audioMeterLock.unlock(); return }
        playoutStallPending = false
        stallRecoveryLastAttemptNanos = now
        let route = audioRouteCache
        meterRecovering = true
        audioMeterLock.unlock()
        guard !isShutdown else { return }
        TelemetryCounters.shared.audioStallRecoveryTotal.increment()
        Diag.error("audio playout STALLED: scheduled audio unconsumed ≥3s with "
            + "every arrival dropped at the backlog gates (output device "
            + "slept/vanished?) - rebuilding: node stop → engine ensure-running "
            + "→ re-prime; route \(route, privacy: .private)", "Stream.Audio")
        playerNode.stop()
        if !engine.isRunning {
            if let failure = startEngineSafely() {
                Diag.error("audio engine restart in stall recovery FAILED: \(failure, privacy: .private)", "Stream.Audio")
                lastOutputFormat = nil
                scheduleEngineRestartRetry()
            } else {
                engineRestartRetries = 0
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
            // A device mid-transition can RAISE here; a nil baseline makes the next
            // change notification read "moved" and reconnect.
            let connected = gl_objc_try {
                self.engine.connect(self.varispeed, to: self.engine.mainMixerNode, format: fmt)
            }
            if !connected {
                Diag.error("audio graph reconnect after config change raised (device "
                    + "mid-transition?) - reconnecting on the next change", "Stream.Audio")
                lastOutputFormat = nil
            }
        }
        if !engine.isRunning {
            if let failure = startEngineSafely() {
                Diag.error("audio engine restart after config change FAILED: \(failure, privacy: .private)", "Stream.Audio")
                lastOutputFormat = nil
                scheduleEngineRestartRetry()
            } else {
                engineRestartRetries = 0
            }
        }
        applyOutputMute()
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
