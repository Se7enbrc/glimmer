// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AVFoundation
import AudioToolbox
import Foundation

extension AudioDecoder {
    func initDecoderCore(channelCount chCount: Int, sampleRate: Int32,
                         streams strms: Int32, coupledStreams coupled: Int32,
                         samplesPerFrame spf: Int, mapping map: [UInt8]) -> Int32 {
        AudioDiagnostics.queue.sync {}
        beginGraphChange()
        defer { endGraphChange() }
        removeAudioRouteListener()
        removeDeviceListeners()
        halOutput = nil
        decoder = nil
        inputFormat = nil
        deviceRecoveryStarted = 0
        resetPacketSplice()
        engineRestartGeneration &+= 1
        outputDiagnosticRequests = AudioOutputDiagnosticRequests()
        engineRestartRetries = 0
        primeEdgeRetryAtNanos = 0
        primeEdgeFailureStreak = false
        channelCount = chCount
        samplesPerFrame = spf
        streams = Int(strms)
        coupledStreams = Int(coupled)
        mapping = map
        let route = preparePlayoutForSession(sampleRate: sampleRate)
        decoder = OpusDecoder(sampleRate: sampleRate, channels: channelCount, streams: streams,
                              coupledStreams: coupledStreams, mapping: mapping, samplesPerFrame: spf)
        guard decoder != nil else {
            log.error("Opus decoder setup failed: \(chCount) ch, \(strms)/\(coupled) streams, \(sampleRate) Hz")
            return -1
        }
        guard let format = prepareInputFormat(sampleRate: sampleRate) else { return -1 }
        preparePCMStorage(format: format)
        _ = maintenanceSource
        _ = linkResolveSource
        outputGraphNeedsReconnect = true
        if let failure = startEngineSafely() {
            Diag.error("audio engine start FAILED: \(failure, privacy: .private)", "Stream.Audio")
            scheduleEngineRestartRetry()
        }
        installAudioRouteListener(initial: route)
        installRenderMonitor()
        return 0
    }

    private func preparePlayoutForSession(sampleRate: Int32) -> AudioRoute {
        // Load memory before the meter lock so cold pre-roll starts at the PC's
        // learned depth instead of paying for startup underruns again.
        let seed = Self.loadCushionSeed(environment: platform.environment(), defaults: defaults)
        // Per-host+device skew seed: start the resampler's integral at the persisted
        // offset between the PC's clock and THIS output device's clock, so the
        // session begins pre-corrected instead of re-drifting into underruns.
        let route = platform.sampleRoute()
        let skewKey = Self.resamplerSkewKey(host: seed.host, deviceUID: route.uid)
        let skewSeedPpm = Self.loadResamplerSkewSeed(key: skewKey, defaults: defaults)
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

    package static func channelLayout(channels: UInt32) -> AudioChannelLayoutTag {
        switch channels {
        case 1: return kAudioChannelLayoutTag_Mono
        case 6: return kAudioChannelLayoutTag_AudioUnit_5_1
        case 8: return kAudioChannelLayoutTag_AudioUnit_7_1
        default: return kAudioChannelLayoutTag_Stereo
        }
    }

    private func prepareInputFormat(sampleRate: Int32) -> AVAudioFormat? {
        // Sunshine's 5.1 order matches Apple's layout. In 7.1, rear and side
        // pairs swap places; reorder output without changing the opus mapping.
        outputReorder = channelCount == 8 ? [0, 1, 2, 3, 6, 7, 4, 5] : nil
        guard let layout = AVAudioChannelLayout(layoutTag: Self.channelLayout(channels: UInt32(channelCount))) else {
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

    private func resetPlayoutStateForSession(seed: CushionSeed, sampleRate: Int32,
                                             skewSeedPpm: Double, skewKey: String) {
        let seedNowNanos = DispatchTime.now().uptimeNanoseconds
        audioMeterLock.lock()
        meterSampleRate = Double(sampleRate)
        framesScheduled = 0; framesPlayed = 0; pendingSilenceFrames = 0
        driftAnchorNanos = 0; driftAnchorFramesPlayed = 0
        resamplerDriftWindow = ResamplerDriftWindow()
        resamplerSkewConverged = false
        resamplerIntegralPpm = skewSeedPpm; resamplerEpsPpm = 0
        resamplerEverEngaged = false
        lastResamplerSkewSaveNanos = 0; lastSavedResamplerSkewPpm = .nan
        resamplerSkewMemoryKey = skewKey
        resamplerQuietIntegralSumPpm = 0; resamplerQuietTicks = 0
        resamplerSetpointMs = 0; resamplerSetpointMovedNanos = 0
        playoutStarted = false; playoutDrained = false; meterShutdown = false
        // Reconnect must clear the teardown latch or packets arrive while every decode is rejected.
        if isShutdown { Diag.info("audio decoder re-init - isShutdown reset (reconnect)", "Stream.Audio") }
        isShutdown = false
        engineRunning = false
        // Start ring consumption only after pre-roll. A seeded target must earn its first quiet window;
        // session telemetry resets its own minimum-fill window independently.
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
        pendingUnderrunTargetMs = nil; underrunArrivalGapNanos = 0
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

    func startEngineSafely() -> String? {
        if outputGraphNeedsReconnect, halOutput != nil { discardOutput() }
        let status: OSStatus
        if let startOutput {
            status = startOutput(self)
        } else {
            guard let inputFormat else { return "audio graph has no input format" }
            do {
                if halOutput == nil || outputGraphNeedsReconnect {
                    installDeviceListeners()
                    let output = try platform.makeOutput(inputFormat)
                    halOutput = output
                    observedRingFrames = 0
                    observedRingSilence = 0
                    observedRingUnderruns = 0
                    outputGraphNeedsReconnect = false
                    installDeviceListeners()
                    AudioPipelineTelemetry.shared.noteOutput(latencyMs: output.latencyMs)
                    Diag.notice("audio HAL ready: \(Int(output.sampleRate)) Hz, \(output.channels) channels, "
                        + "render-to-output \(output.latencyMs)ms", "Stream.Audio")
                }
                status = halOutput?.start() ?? kAudioUnitErr_Uninitialized
            } catch let failure as AudioOutput.Failure {
                status = failure.status
            } catch {
                return error.localizedDescription
            }
        }
        audioMeterLock.withLock { engineRunning = status == noErr }
        guard status == noErr else {
            outputGraphNeedsReconnect = true
            return "OSStatus \(status)"
        }
        outputGraphNeedsReconnect = false
        applyOutputMute()
        return nil
    }

    func applyOutputMute() {
        halOutput?.queue.pointee.muted.store(outputMuted, ordering: .relaxed)
    }

    public func setOutputMuted(_ muted: Bool) {
        beginGraphChange()
        defer { endGraphChange() }
        outputMuted = muted
        applyOutputMute()
    }

    public func shutdown() {
        beginGraphChange()
        defer { endGraphChange() }
        guard !isShutdown else { return }
        isShutdown = true
        deviceRecoveryStarted = 0
        renderMonitor?.cancel()
        renderMonitor = nil
        engineRestartGeneration &+= 1
        outputDiagnosticRequests = AudioOutputDiagnosticRequests()
        // Gate evidence before discarding PCM: teardown must never teach a deeper cushion.
        audioMeterLock.withLock {
            meterShutdown = true
            engineRunning = false
        }
        removeAudioRouteListener()
        removeDeviceListeners()
        halOutput = nil
        decoder = nil
        resetPacketSplice()
    }

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
        beginGraphChange(); defer { endGraphChange() }
        guard generation == engineRestartGeneration,
              !isShutdown, !engineRunning, inputFormat != nil else { return }
        if let failure = startEngineSafely() {
            Diag.error("audio engine restart retry \(attempt) failed: \(failure, privacy: .private)", "Stream.Audio")
            if attempt == Self.maxEngineRestartRetries {
                Diag.error("audio restart ladder exhausted; packet and device recovery remain armed", "Stream.Audio")
            }
            scheduleEngineRestartRetry()
        } else {
            engineRestartRetries = 0
            Diag.notice("audio engine restart retry \(attempt) succeeded", "Stream.Audio")
        }
    }

    func startPlayoutAtPrimeEdge(allowRecovery: Bool = true) -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now >= primeEdgeRetryAtNanos else { return false }
        if !allowRecovery && !engineRunning {
            maintenanceSource.add(data: 1)
            return false
        }
        if allowRecovery, !ensureEngineAtPrimeEdge(now: now) { return false }
        guard engineRunning else { return false }
        halOutput?.queue.pointee.enabled.store(true, ordering: .releasing)
        primeEdgeFailureStreak = false
        primeEdgeRetryAtNanos = 0
        return true
    }

    // Maintenance and prime recovery query HAL off the render thread; the cached gauge cannot detect sleep.
    func refreshOutputRunningState() {
        guard engineRunning, let output = halOutput, !output.isRunning else { return }
        audioMeterLock.withLock { engineRunning = false; meterRecovering = true }
        output.queue.pointee.enabled.store(false, ordering: .releasing)
        outputGraphNeedsReconnect = true
    }

    func ensureEngineAtPrimeEdge(now: UInt64) -> Bool {
        refreshOutputRunningState()
        guard now >= primeEdgeRetryAtNanos else { return false }
        if !engineRunning {
            let failure = startEngineSafely()
            guard failure == nil, engineRunning else {
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
        return true
    }

    func recoverIfPlayoutStalled() {
        let pending = audioMeterLock.withLock {
            guard playoutStallPending else { return false }
            playoutStallPending = false
            stallRecoveryLastAttemptNanos = DispatchTime.now().uptimeNanoseconds
            return true
        }
        guard pending, !isShutdown else { return }
        TelemetryCounters.shared.audioStallRecoveryTotal.increment()
        Diag.error("audio playout STALLED: scheduled audio unconsumed ≥3s - rebuilding; "
            + "route \(audioRouteCache, privacy: .private)", "Stream.Audio")
        rebuildOutput()
    }

    func handleEngineConfigurationChange(changedAt: UInt64 = DispatchTime.now().uptimeNanoseconds,
                                         generation: UInt64? = nil,
                                         beforeGraphChange: @Sendable () -> Void = {}) {
        beginGraphChange()
        defer { endGraphChange() }
        guard !isShutdown, inputFormat != nil,
              generation == nil || generation == engineRestartGeneration else { return }
        beforeGraphChange()
        rebuildOutput(startedAt: changedAt)
        Diag.notice("audio engine config change handled (running \(engineRunning))", "Stream.Audio")
        queueOutputDiagnosticLocked()
    }

    private func rebuildOutput(startedAt: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        if deviceRecoveryStarted == 0 { deviceRecoveryStarted = startedAt }
        discardOutput()
        outputGraphNeedsReconnect = true
        if let failure = startEngineSafely() {
            Diag.error("audio engine restart after config change FAILED: \(failure, privacy: .private)", "Stream.Audio")
            scheduleEngineRestartRetry()
        } else {
            engineRestartRetries = 0
        }
    }

    private func discardOutput() {
        audioMeterLock.withLock { meterRecovering = true; engineRunning = false }
        removeDeviceListeners()
        halOutput = nil
        resetPacketSplice()
        audioMeterLock.withLock {
            framesPlayed = framesScheduled
            pendingSilenceFrames = 0
            pendingUnderrunTargetMs = nil
            underrunArrivalGapNanos = 0
            primed = false
            playoutStarted = false
            playoutDrained = false
            buffersSinceArm = 0
        }
    }
}
