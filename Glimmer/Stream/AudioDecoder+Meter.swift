//
//  AudioDecoder+Meter.swift
//
//  The P1 AUDIO playout meter + cushion machinery: the schedule-side
//  trim-toward-target / over-run gates and drift re-baseline, the pre-roll
//  prime + re-prime silence backfill, the completion-side playhead +
//  under-run edge (with its rate-limited route-carrying NOTICE) + adaptive
//  cushion grow/decay, the published audio-state gauge, and the
//  default-output-route sampler the breadcrumbs read. Split from
//  AudioDecoder.swift - same idiom as the FramePacer split, to
//  keep that file under the length limit. The stored meter state stays on
//  the class (stored properties can't live in extensions); see the property
//  docs there for the locking + design rationale.
//

import AVFoundation
import CoreAudio
import Foundation

extension AudioDecoder {

    // MARK: - Tunables (the knobs of THIS file's machinery; the cushion ladder's
    // base/step/cap and the over-run ceiling stay with the design narrative in
    // AudioDecoder.swift, the decay clock with its arbitration in
    // AudioDecoder+CushionMemory.swift)

    /// Hysteresis (ms) the backlog must sit ABOVE the cushion target before the
    /// steady-state trim engages (~3 packets). Without it the trim fires on every
    /// packet the moment the backlog touches target, machine-gunning the post-gap
    /// catch-up clump into back-to-back mid-stream 5ms chops (audible crackle -
    /// Opus is stateful).
    static let playoutTrimHysteresisMs: Double = 15
    /// Minimum spacing (ns) between trims: at most one 5ms chop per ~100ms, so a
    /// standing excess bleeds off at ~50ms/s through normal playback instead of
    /// being spliced out all at once.
    static let playoutTrimMinIntervalNanos: UInt64 = 100_000_000
    /// Grace (ns) after a (re-)prime arm during which BOTH backlog gates (trim +
    /// over-run ceiling) stand down. The post-drain catch-up clump IS the cushion
    /// rebuild the link just proved it needs - chopping it re-creates the very gap
    /// it follows. The ceiling resumes after the grace as the true bad-link backstop.
    /// DOUBLES as the backfill deadline: a re-prime reaching grace expiry with fill
    /// still a step short of target hands the measured deficit to the silence
    /// backfill (`backfillCushion`) - by then the clump had its full window.
    static let reprimeGraceNanos: UInt64 = 250_000_000
    /// Safety fallback FLOOR: prime (start playback) after at most this many
    /// buffers regardless of the measured cushion, so a very low-bitrate /
    /// near-silent stream (where the depth never reaches the target before
    /// completions drain it) never wedges un-started. 12 buffers ≈ 60ms; for a
    /// deeper SEEDED target, `maybePrime` scales the count up to the target so
    /// the seed isn't paid away - worst ~160ms, tiny vs the <1s cold budget.
    static let primeFallbackBufferCount: UInt64 = 12
    /// Minimum spacing (ns) between under-run NOTICE lines (Diag ring + session
    /// file). The `audio_underrun_total` counter stays exact; this bounds only
    /// the BREADCRUMB rate so a cascade can't flood the 2000-entry Diag ring -
    /// edges suppressed by the limit ride the next line as a count.
    static let underrunNoticeMinIntervalNanos: UInt64 = 1_000_000_000

    // MARK: - P1 AUDIO meter (buffer fill / under-run / over-run / A/V drift)

    /// Account one decoded buffer about to be scheduled. Returns true iff it should
    /// be DROPPED - either TRIMMED back toward the steady-state cushion target, or
    /// (for bad links) dropped at the hard over-run ceiling. On the decode path under
    /// the tiny meter lock (never `stateLock`). Stamps the playout-start anchor on the
    /// first buffer.
    func meterRegisterScheduleOrOverrun(frames: UInt64) -> Bool {
        audioMeterLock.lock()
        let aheadFrames = framesScheduled &- framesPlayed
        let aheadMs = meterSampleRate > 0 ? Double(aheadFrames) / meterSampleRate * 1000.0 : 0
        // (a) STEADY-STATE TRIM-TOWARD-TARGET. Once primed and running (not mid-
        // (re)prime: `primed && !playoutDrained`), keep the scheduled-ahead backlog
        // clipped to the adaptive cushion target. The ROOT cause of the ~235ms pin was
        // that the cap governed only PRE-ROLL: after an early underrun grew the cushion
        // (or receive ran a touch ahead), the backlog had no trim/decay and stayed deep
        // forever. Here, when the queue holds a hysteresis band ABOVE target, we
        // decline to enqueue this newest packet so the playhead walks the backlog back
        // down. Each trim is a mid-stream 5ms splice (Opus is stateful), so two extra
        // guards keep the walk-down inaudible: the rate limit (one trim per ~100ms -
        // excess bleeds at ~50ms/s through playback instead of back-to-back chops) and
        // the post-(re)prime grace (the catch-up clump after a drain IS the cushion
        // rebuild; chopping it re-creates the gap it follows). Counted as a TRIM
        // (`audioTrimTotal`) - a DESIGNED latency-bounding drop, deliberately split
        // from the over-run ceiling's pathology counter so the two can never be
        // conflated again. Gated on `primed` so it never starves the pre-roll, and on
        // `!playoutDrained` so a segment rebuilding its cushion after a drain isn't
        // trimmed before it can re-prime.
        if primed && !playoutDrained && aheadMs >= playoutTargetMs + Self.playoutTrimHysteresisMs {
            // Clock reads live only inside the would-trim/would-drop branches - the
            // steady-state path at/below target stays clock-free.
            let now = DispatchTime.now().uptimeNanoseconds
            if now >= gateGraceUntilNanos && now &- lastTrimNanos >= Self.playoutTrimMinIntervalNanos {
                lastTrimNanos = now
                audioMeterLock.unlock()
                TelemetryCounters.shared.audioTrimTotal.increment()
                return true
            }
            // In grace or rate-limited: fall through and schedule. The backlog rides
            // above target briefly; the next eligible trim takes the excess back down.
        }
        // (b) HARD OVER-RUN ceiling backstop - the dogshit-link safeguard. The trim
        // above holds steady state at the target; this only fires if the link is bad
        // enough that the backlog blew past the ceiling anyway (e.g. before prime, or
        // a burst). It too stands down during the post-(re)prime grace - a max-deep
        // cushion rebuild may legitimately overshoot the ceiling for a moment - and it
        // is the ONLY branch still counted as an over-run (ceiling = pathology,
        // trim = design).
        if playoutStarted && aheadMs > effectiveOverrunCeilingMs {
            let now = DispatchTime.now().uptimeNanoseconds
            if now >= gateGraceUntilNanos {
                audioMeterLock.unlock()
                TelemetryCounters.shared.audioOverrunTotal.increment()
                return true
            }
        }
        // Drift anchor (re-)baseline: on the very FIRST start, and on every RESTART
        // after a drain (`playoutDrained`). Anchoring the wall clock AND the
        // media-played reference here makes the drift metric measure only the
        // current continuous-playout segment - so the wall-vs-media gap that
        // accrued while the queue sat drained is NOT folded into drift (the
        // +6448ms step-jump). Cheap: a couple of stores under the lock we already
        // hold, at the schedule edge only.
        if !playoutStarted || playoutDrained {
            // COLD-START arm vs mid-stream RE-prime - captured BEFORE the start
            // flag flips. The cold path keeps its paused pre-roll + buffer-count
            // fallback; a re-prime instead takes the grace-then-backfill rebuild
            // in `maybePrime` (the node never paused, so only a catch-up clump or
            // the backfill can restore standing fill).
            rebuildIsReprime = playoutStarted
            playoutStarted = true
            driftAnchorNanos = DispatchTime.now().uptimeNanoseconds
            driftAnchorFramesPlayed = framesPlayed
            // Arm the gate grace on this same edge (cold start or post-drain
            // restart): the next ~250ms of arrivals are the cushion (re)build - the
            // catch-up clump the link just proved it needs - so neither the trim nor
            // the ceiling may chop them. Reuses the clock read above. A drain
            // recurring inside an open grace re-arms it: each new gap earns its own
            // clump window (the jittery-link rebuild path), and `maybePrime`'s
            // backfill waits on the freshest deadline - measured drains space
            // out seconds apart, far beyond the grace, so the backfill still lands.
            gateGraceUntilNanos = driftAnchorNanos &+ Self.reprimeGraceNanos
            // A drain (or the cold start) means the cushion is empty: re-arm the
            // pre-roll STATE MACHINE so the backlog gates stand down while the
            // cushion rebuilds (post-gap catch-up clump, or the grace-expiry
            // silence backfill when none forms). The node itself keeps playing -
            // the completion path makes no AV calls (it races teardown), so there
            // is no paused pre-roll on re-arm. `primed` is only cleared on the
            // EDGE (the first schedule after a drain) so we don't re-prime
            // mid-segment; the under-run completion handler counts the gap.
            if primed {
                primed = false
                rePrimeCount &+= 1
            }
            buffersSinceArm = 0
        }
        framesScheduled &+= frames
        buffersSinceArm &+= 1
        // A new buffer is queued behind the playhead → no longer drained; re-arm
        // the under-run edge so the NEXT drain counts.
        playoutDrained = false
        audioMeterLock.unlock()
        return false
    }

    /// PRE-ROLL / RE-PRIME arbiter, on the decode path after each schedule
    /// (`stateLock` held by the caller, so the AV calls here are serialized
    /// against `shutdown()`). No-op once primed - the steady-state cost is one
    /// lock + a compare. Three un-primed paths:
    ///   * TARGET REACHED (cold pre-roll filled, or a re-prime's catch-up clump
    ///     stacked back up - the jittery-link rebuild): mark primed and `play()`.
    ///     Only the COLD-START `play()` actually starts the node; on a re-prime it
    ///     never paused (the completion path makes no AV calls), so `play()` is a
    ///     harmless no-op marking the state-machine edge.
    ///   * COLD-START FALLBACK: after `primeFallbackBufferCount` buffers, start
    ///     anyway so a near-silent / very-low-bitrate stream can't wedge the
    ///     session un-started.
    ///   * RE-PRIME PAST THE GRACE with fill still a step short of target: the
    ///     clump never formed (steady link - host pacing 1:1, or a playback-side
    ///     drain), so waiting longer cannot add fill; hand the measured deficit to
    ///     `backfillCushion`. The fallback deliberately does NOT apply here: it
    ///     used to declare the rebuild done at ~15ms standing fill while the
    ///     target ramped to 150ms - the under-run cascade.
    /// Decides under the meter lock; AV calls happen OUTSIDE the lock
    /// (AVAudioPlayerNode is thread-safe and we must not hold the meter lock
    /// across an AV call).
    func maybePrime(format: AVAudioFormat) {
        audioMeterLock.lock()
        if primed { audioMeterLock.unlock(); return }
        let aheadFrames = framesScheduled &- framesPlayed
        let aheadMs = meterSampleRate > 0 ? Double(aheadFrames) / meterSampleRate * 1000.0 : 0
        if aheadMs >= playoutTargetMs {
            primed = true
            audioMeterLock.unlock()
            // Cushion is built - begin (or, re-prime, continue) gapless playback;
            // the already-queued buffers drain ahead of the playhead as the cushion.
            playerNode.play()
            return
        }
        if !rebuildIsReprime {
            // The wedge-proof fallback SCALES with the (possibly seeded)
            // target: the fixed 12 buffers covered the 30ms base, but a
            // per-host seed of 80-150ms would otherwise always prime at the
            // fallback's ~60ms and pay the seed's protection away on the
            // first gap. Target/5ms-per-packet + 2 slack; a silent stream
            // still un-wedges in ≤~160ms, far under the <1s cold-start budget.
            let fallbackCount = max(Self.primeFallbackBufferCount,
                                    UInt64(playoutTargetMs / 5.0) + 2)
            guard buffersSinceArm >= fallbackCount else {
                audioMeterLock.unlock()
                return
            }
            primed = true
            audioMeterLock.unlock()
            playerNode.play()
            return
        }
        // Mid-stream re-prime, fill short of target: give the catch-up clump its
        // full grace window first (the clock read is transient - this branch lives
        // at most one grace per drain, ~50 packets).
        let now = DispatchTime.now().uptimeNanoseconds
        guard now >= gateGraceUntilNanos else {
            audioMeterLock.unlock()
            return
        }
        let deficitMs = playoutTargetMs - aheadMs
        audioMeterLock.unlock()
        backfillCushion(deficitMs: deficitMs, format: format)
    }

    /// RE-PRIME silence backfill - the steady-link cushion rebuild. Schedules ONE
    /// zeroed buffer of (target − fill) ms so the standing cushion reaches the
    /// adaptive target immediately, then marks the re-prime complete. WHY silence:
    /// after a drain the gap is already audible, and on a link delivering at
    /// exactly real-time rate NOTHING else can add fill - the target ratchet was
    /// pure cosmetics (fill pinned a couple steps above empty vs a much deeper
    /// target through an under-run cascade). One deliberate, bounded (≤ cushion cap) quiet stretch right
    /// behind the gap buys the headroom that ends the cascade - equivalent in gap
    /// length to holding the node for the same span, without touching node state,
    /// so the no-AV-calls-on-unserialized-paths discipline stands. JITTERY links
    /// never reach here: their post-gap clump stacks fill to target inside the
    /// grace and `maybePrime` exits on the target-reached path; a clump arriving
    /// LATE (after a backfill) overshoots by at most its own size, which the
    /// rate-limited trim - and, past 190ms, the ceiling backstop - walks back
    /// down. Caller is the decode path with `stateLock` held (AV calls serialized
    /// against `shutdown()`).
    private func backfillCushion(deficitMs: Double, format: AVAudioFormat) {
        let frames = AVAudioFrameCount((deficitMs / 1000.0) * format.sampleRate)
        // Sub-step deficits aren't worth a splice - fill is already within one
        // ratchet quantum of target. That case (and a failed allocation) primes
        // as-is rather than wedging the state machine un-primed.
        guard deficitMs >= Self.playoutCushionStepMs, frames > 0,
              let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            audioMeterLock.lock()
            primed = true
            audioMeterLock.unlock()
            playerNode.play()
            return
        }
        silence.frameLength = frames
        // Zero explicitly - AVAudioPCMBuffer does not guarantee zeroed memory, and
        // "silence" must never be heap garbage.
        if let channels = silence.floatChannelData {
            for channel in 0..<Int(format.channelCount) {
                channels[channel].update(repeating: 0, count: Int(frames))
            }
        }
        let silenceFrames = UInt64(frames)
        audioMeterLock.lock()
        framesScheduled &+= silenceFrames
        // Resident silence for the av_skew correction (-= at completion): this
        // silence inflates buffer fill without advancing the audio RTP position.
        pendingSilenceFrames &+= silenceFrames
        // Keep the drift gauge honest: the silence is media the wall-time stream
        // never delivered, so advance the segment's media-played reference by the
        // same amount - wall − media − fill stays an identity instead of stepping
        // −deficit for the rest of the segment. (Until the silence finishes
        // playing the anchor can sit ahead of `framesPlayed`; `publishAudioState`'s
        // guard reports drift as absent for that moment, then resumes clean.)
        driftAnchorFramesPlayed &+= silenceFrames
        primed = true
        let targetMs = playoutTargetMs
        let route = audioRouteCache
        audioMeterLock.unlock()
        // Accounted above, scheduled here (outside the meter lock, AV-call
        // discipline): a completion in the sliver between sees fill briefly
        // overstated - harmless, and it can't mistake the moment for a drain.
        playerNode.scheduleBuffer(silence) { [weak self] in
            self?.meterCompleteOnePlayout(frames: silenceFrames, isSilence: true)
        }
        playerNode.play() // no-op mid-stream; keeps the prime edge uniform
        Diag.notice(
            "audio cushion backfill +\(Int(deficitMs.rounded()))ms silence → \(Int(targetMs))ms standing fill "
            + "- no catch-up clump within the re-prime grace (steady link); route \(route)",
            "Stream")
    }

    /// One scheduled buffer finished playing (the player's completion handler, on
    /// an arbitrary thread). Advance the playhead and detect an UNDER-RUN - the
    /// player drained to empty with the stream still active (an audible gap). Tiny
    /// meter lock only; no decode/shutdown contention - and deliberately ZERO
    /// AV-node calls: this thread is never serialized against `shutdown()`, so a
    /// pause()/play() here would race teardown. The post-drain cushion rebuild
    /// belongs to the DECODE path - the catch-up clump under the gate grace, or
    /// the grace-expiry silence backfill - never this handler's.
    func meterCompleteOnePlayout(frames: UInt64, isSilence: Bool = false) {
        audioMeterLock.lock()
        framesPlayed &+= frames
        // A corrector-inserted silence buffer finished: release its resident
        // contribution so the av_skew fill correction tracks only buffered silence.
        if isSilence {
            pendingSilenceFrames = pendingSilenceFrames >= frames ? pendingSilenceFrames &- frames : 0
        }
        // The scheduled-ahead trough right at this completion - the truest low of the
        // backlog (a completion is exactly where the queue is shallowest). Fed to the
        // reset-on-read MIN-fill window below so the exporter can prove the cushion
        // holds above 0; the 1Hz last-writer-wins gauge can miss this instantaneous low.
        let aheadFrames = framesScheduled &- framesPlayed
        let rate = meterSampleRate
        let fillMs = rate > 0 ? Double(aheadFrames) / rate * 1000.0 : 0
        // The same trough is the decay window's NEAR-MISS evidence (the
        // limit-cycle fix): a dip inside one step of empty must hold depth.
        if rate > 0, fillMs < quietWindowMinFillMs { quietWindowMinFillMs = fillMs }
        // Under-run EDGE: this completion drained the backlog to empty while
        // playout is active AND we weren't already drained - a true gap, not a
        // steady 1-deep queue. Latch so we count it once until the next schedule.
        // TEARDOWN BURST GUARD: `shutdown()` raises `meterShutdown` (this lock's
        // domain) BEFORE `playerNode.stop()`, because stop() fires the completion
        // of EVERY still-queued buffer (.dataConsumed semantics: consumed OR
        // stopped) - with a standing cushion that's a 6-30 handler burst whose
        // last completion drains the playhead exactly like a starvation drain.
        // Un-gated, that minted a synthetic under-run on EVERY session end:
        // target ratcheted +10ms, floor EWMA-pulled, both PERSISTED per-host -
        // sub-10-min sessions walked toward the 150ms cap across sessions (the
        // disguised-permanent-pin class; the same completion-handler-vs-shutdown
        // race the no-AV-calls rule guards, hitting the STATE MACHINE instead of
        // the node). The burst still drains its bookkeeping above - playhead,
        // trough, drained latch - so mid-session logic is untouched; ONLY the
        // evidence edges (ratchet/floor/persist/counter/NOTICE, and the decay
        // clock below) are gated.
        let stopping = meterShutdown
        let drainedNow = framesPlayed >= framesScheduled
        let isUnderrunEdge = drainedNow && !playoutDrained && !stopping
        if drainedNow { playoutDrained = true }
        var emitNotice = false
        var noticeRoute = ""
        var noticeTargetMs = 0.0
        var noticeSuppressed: UInt64 = 0
        var memoryWrite: CushionMemoryWrite?
        if isUnderrunEdge {
            // ADAPTIVE cushion: a real drain is evidence this link needs more
            // headroom - grow the target one step (capped), like the video pacer
            // deepening its jitter buffer on measured starvation. Only on the edge,
            // so a steady drained queue doesn't ratchet it up. The next re-prime
            // builds the deeper cushion (clump or backfill).
            let failedTargetMs = playoutTargetMs
            if playoutTargetMs < effectiveCushionMaxMs {
                playoutTargetMs = min(playoutTargetMs + Self.playoutCushionStepMs,
                                      effectiveCushionMaxMs)
            }
            // Every under-run (capped or not) restarts the decay quiet window: depth
            // is held by recurring evidence, decayed only by its sustained absence.
            quietSinceNanos = DispatchTime.now().uptimeNanoseconds
            // The level that just FAILED feeds the loss floor + per-host memory
            // (the limit-cycle fix - see AudioDecoder+CushionMemory.swift).
            memoryWrite = cushionNoteUnderrunLocked(now: quietSinceNanos,
                                                    failedTargetMs: failedTargetMs)
            // Under-run NOTICE breadcrumb (rate-limited; counters stay exact): the
            // session log carried ZERO under-run lines, so a cascade's trigger
            // class (BT detach? hidden-window QoS?) was unattributable postmortem.
            // The route rides along from the listener-maintained cache - a plain
            // String read; this thread makes no CoreAudio/AV calls.
            if quietSinceNanos &- lastUnderrunNoticeNanos >= Self.underrunNoticeMinIntervalNanos {
                lastUnderrunNoticeNanos = quietSinceNanos
                emitNotice = true
                noticeRoute = audioRouteCache
                noticeTargetMs = playoutTargetMs
                noticeSuppressed = underrunNoticesSuppressed
                underrunNoticesSuppressed = 0
            } else {
                underrunNoticesSuppressed &+= 1
            }
        } else if !stopping, playoutTargetMs > Self.playoutCushionBaseMs {
            // DECAY: a grown cushion is temporary, never a permanent pin - but
            // the bare 60s clock was a measured limit cycle (it stepped INTO
            // the ambient loss floor every ~90s). The step now also requires a
            // clean near-miss window and clearance over the learned floor; the
            // floor's own slow decay keeps every hold temporary. Arbitration +
            // jittery-link rationale: AudioDecoder+CushionMemory.swift. One
            // clock read per completion, only while elevated.
            memoryWrite = cushionQuietAdjustLocked(now: DispatchTime.now().uptimeNanoseconds)
        }
        audioMeterLock.unlock()
        if rate > 0 {
            TelemetryCounters.shared.noteAudioBufferFill(ms: fillMs)
        }
        if isUnderrunEdge {
            TelemetryCounters.shared.audioUnderrunTotal.increment()
            if emitNotice {
                emitUnderrunNotice(route: noticeRoute, targetMs: noticeTargetMs,
                                   suppressed: noticeSuppressed)
            }
        }
        // Rare learn/decay edges persist off the lock (UserDefaults + gauge).
        if let memoryWrite { commitCushionMemory(memoryWrite) }
        publishAudioState()
    }

    /// Render + emit the under-run NOTICE (post-lock - Diag only: a lock + string
    /// + os_log, never an AV/CoreAudio call; this runs on the player's completion
    /// thread). The ordinal reads the just-incremented session counter so log
    /// lines and `audio_underrun_total` cross-reference 1:1.
    private func emitUnderrunNotice(route: String, targetMs: Double, suppressed: UInt64) {
        let ordinal = TelemetryCounters.shared.audioUnderrunTotal.value
        let backlog = suppressed > 0 ? " (+\(suppressed) since last line)" : ""
        Diag.notice(
            "audio under-run #\(ordinal)\(backlog) - playout drained to empty; route \(route), "
            + "cushion target \(Int(targetMs))ms",
            "Stream")
    }

    /// Publish the live audio playout state (buffer fill + audio clock drift) to
    /// the always-live telemetry gauge. Called off the per-sample inner loop (at
    /// schedule + at completion); the exporter reads it at 1Hz. The audio clock
    /// drift is the audio-playout-vs-WALL-CLOCK slip: wall-clock elapsed since
    /// playout started minus the audio media duration actually played (net of the
    /// buffer cushion). It measures the audio device clock against real time - it
    /// is NOT a cross-stream A/V delta (nothing here compares against the video
    /// present clock), so it's named honestly for what it is. A growing positive
    /// value means the audio clock is running slow relative to wall time.
    func publishAudioState() {
        audioMeterLock.lock()
        let aheadFrames = framesScheduled &- framesPlayed
        let residentSilenceFrames = pendingSilenceFrames
        let rate = meterSampleRate
        let started = playoutStarted
        let anchorNanos = driftAnchorNanos
        let anchorFramesPlayed = driftAnchorFramesPlayed
        let playedFrames = framesPlayed
        let rePrimes = rePrimeCount
        let engineUp = engineRunning
        // The adaptive cushion target rides the same gauge: its VALUE only moves
        // on the cold grow/decay edges, but carrying it here (one load under the
        // lock already held) is what lets every exported row judge fill AGAINST
        // target - without it a fill hugging a flat ceiling is indistinguishable
        // from the old disguised-permanent-give-up re-pin.
        let targetMs = playoutTargetMs
        // Engage the drift resampler only in steady playout - the SAME gate the trim
        // uses (Meter trim path). During pre-roll / re-prime / drain the rebuild
        // machinery owns recovery and driveResampler slews the rate back to 1.0.
        let resamplerEngaged = primed && !playoutDrained
        // One Bool under the lock already held: the cushion memory's one-shot
        // link resolve (the route probe feeds ~1-2s after audio bring-up).
        let needsLinkResolve = !cushionLinkResolved
        audioMeterLock.unlock()
        if needsLinkResolve { resolveCushionLink() }
        guard rate > 0 else { return }
        // Surface resident corrector-silence to the A/V-skew meter so it subtracts
        // it from buffer fill: the silence is buffered media the audio RTP clock
        // never advanced past, so counting it makes audio read falsely "late".
        AudioVideoSkewStore.shared.setResidentSilenceMs(
            Double(residentSilenceFrames) / rate * 1000.0)

        let bufferFillMs = Double(aheadFrames) / rate * 1000.0
        // Drive the drift-tracking resampler (self-rate-limited to ~4Hz inside):
        // steers the varispeed rate by the buffer-fill error to absorb the host↔Mac
        // clock skew. Single caller, so the resampler state needs no lock.
        driveResampler(fillMs: bufferFillMs, targetMs: targetMs, engaged: resamplerEngaged)
        var driftMs: Double?
        // Measure drift over the CURRENT playout segment only: wall and media-played
        // are both relative to the segment anchor (re-baselined on each restart),
        // so a prior drain's wall-vs-media gap is excluded rather than pinned.
        if started, anchorNanos != 0, playedFrames >= anchorFramesPlayed {
            let now = DispatchTime.now().uptimeNanoseconds
            if now >= anchorNanos {
                let wallElapsedMs = Double(now &- anchorNanos) / 1_000_000.0
                let segmentFramesPlayed = playedFrames &- anchorFramesPlayed
                let mediaPlayedMs = Double(segmentFramesPlayed) / rate * 1000.0
                // Slip of media-played behind wall time, net of the steady buffer
                // cushion the player intentionally holds ahead - so a constant
                // cushion reads ~0 and only a genuine drift trend shows.
                driftMs = wallElapsedMs - mediaPlayedMs - bufferFillMs
            }
        }
        TelemetryCounters.shared.setAudioState(
            TelemetryCounters.AudioState(
                bufferFillMs: bufferFillMs,
                playoutTargetMs: targetMs,
                audioClockDriftMs: driftMs,
                // The windowed MIN rides its own reset-on-read window
                // (`takeAudioBufferFillMinMs`), not this last-writer-wins gauge, so
                // it isn't carried here; the exporter pulls it directly.
                bufferFillMinMs: nil,
                rePrimeTotal: rePrimes,
                // The resampler's applied rate offset (read on this same ~4Hz single-
                // caller path, no extra lock) - makes the loop visible vs av_skew noise.
                resamplerPpm: resamplerEpsPpm,
                // Engine-running mirror: 1 = AVAudioEngine up. Catches the post-
                // reconnect "packets flow but playout dead" latch in one query.
                engineRunning: engineUp))
    }

    // MARK: - Audio OUTPUT route (under-run attribution breadcrumbs)

    /// Install the default-output-device listener + seed the route cache. Called
    /// once from `initDecoderCore` with `stateLock` held (after the engine is up);
    /// idempotent via the block handle. WHY a listener instead of sampling at the
    /// under-run: route reads are blocking HAL IPC - putting one on the completion
    /// thread (or the 200Hz decode path) would risk the very stalls the cushion
    /// absorbs. The listener pays that cost on its own utility queue, only when
    /// the device actually changes, and the hot paths read a cached String. The
    /// route-CHANGE NOTICE it emits is itself the attribution breadcrumb the
    /// under-run cascades were missing (a BT detach lands here seconds before the
    /// drains it triggers).
    func installAudioRouteListener() {
        guard routeListenerBlock == nil else { return }
        let route = Self.sampleAudioRoute()
        audioMeterLock.lock()
        audioRouteCache = route
        audioMeterLock.unlock()
        // First-sample NOTICE - a new sampler announces itself (success AND
        // failure shape) rather than going silently dark.
        Diag.notice("audio output route: \(route)", "Stream")
        var addr = Self.defaultOutputDeviceAddress
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            let fresh = Self.sampleAudioRoute()
            self.audioMeterLock.lock()
            let previous = self.audioRouteCache
            self.audioRouteCache = fresh
            self.audioMeterLock.unlock()
            if fresh != previous {
                Diag.notice("audio route changed: \(previous) → \(fresh)", "Stream")
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, routeListenerQueue, block)
        if status == noErr {
            routeListenerBlock = block
        } else {
            Diag.notice(
                "audio route listener install failed (OSStatus \(status)) - "
                + "under-run route attribution will not track device switches",
                "Stream")
        }
    }

    /// Remove the route listener (the HAL requires the same address/queue/block
    /// triple). Called from `shutdown()` with `stateLock` held; safe when the
    /// install failed or never ran.
    func removeAudioRouteListener() {
        guard let block = routeListenerBlock else { return }
        routeListenerBlock = nil
        var addr = Self.defaultOutputDeviceAddress
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, routeListenerQueue, block)
    }

    /// The HAL address of the system default OUTPUT device - AVAudioEngine's
    /// outputNode tracks this device, so it IS the playback route.
    private static var defaultOutputDeviceAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    /// One blocking sample of the current default-output route, rendered as
    /// "<device name> [<transport>]" (e.g. "MacBook Pro Speakers [builtin]").
    /// Same probe idiom as `AudioConfig.currentDefaultOutputChannelCount`.
    /// Returns "unknown" if the HAL won't answer - never throws. Call sites: init
    /// + the listener's utility queue only, never a hot path.
    private static func sampleAudioRoute() -> String {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = defaultOutputDeviceAddress
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID) == noErr,
            deviceID != 0 else { return "unknown" }

        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var nameRef: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let nameStatus = withUnsafeMutablePointer(to: &nameRef) {
            AudioObjectGetPropertyData(deviceID, &nameAddr, 0, nil, &nameSize, $0)
        }
        var name = "unnamed"
        if nameStatus == noErr, let cfName = nameRef?.takeRetainedValue() {
            name = cfName as String
        }

        var transportAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var transportSize = UInt32(MemoryLayout<UInt32>.size)
        let transportStatus = AudioObjectGetPropertyData(
            deviceID, &transportAddr, 0, nil, &transportSize, &transport)
        let label = transportStatus == noErr ? Self.transportLabel(transport) : "?"
        return "\(name) [\(label)]"
    }

    /// Short label for the HAL transport type - BT vs built-in vs USB is the
    /// load-bearing distinction for drain attribution.
    private static func transportLabel(_ transport: UInt32) -> String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return "builtin"
        case kAudioDeviceTransportTypeBluetooth,
             kAudioDeviceTransportTypeBluetoothLE: return "bluetooth"
        case kAudioDeviceTransportTypeUSB: return "usb"
        case kAudioDeviceTransportTypeHDMI: return "hdmi"
        case kAudioDeviceTransportTypeDisplayPort: return "displayport"
        case kAudioDeviceTransportTypeThunderbolt: return "thunderbolt"
        case kAudioDeviceTransportTypeAirPlay: return "airplay"
        case kAudioDeviceTransportTypeAggregate: return "aggregate"
        case kAudioDeviceTransportTypeVirtual: return "virtual"
        default: return String(format: "0x%08x", transport)
        }
    }
}
