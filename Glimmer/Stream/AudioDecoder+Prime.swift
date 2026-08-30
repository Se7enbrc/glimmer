//
//  AudioDecoder+Prime.swift
//
//  The PRE-ROLL / RE-PRIME arbiter and its silence backfill: the decode-path
//  half of the playout cushion, which decides when there is enough queued audio
//  to (re)declare playback primed and, when a steady link never produces a
//  catch-up clump, mints the one bounded silence buffer that closes the deficit.
//  Split from AudioDecoder+Meter.swift - same idiom as the FramePacer split, to
//  keep that file under the length limit. The completion-side half (playhead,
//  under-run edge, cushion grow/decay) and the schedule-side gates stay there;
//  the tunables these two read (`primeFallbackBufferCount`, `reprimeGraceNanos`)
//  stay with the rest of the meter's knobs. The stored cushion state lives on
//  the class (stored properties can't live in extensions); see the property docs
//  in AudioDecoder.swift for the locking + design rationale.
//

import AVFoundation
import Foundation

extension AudioDecoder {

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
        if primed {
            // RESOLVE TOP-UP (one-shot, armed by resolveCushionLink): the link
            // resolve adopted a target deeper than the standing fill. Close the
            // deficit NOW with the silence backfill - this is the decode path
            // (stateLock held), the one place AV calls are serialized against
            // shutdown - instead of letting the host's paced startup inflow
            // drain-cascade the difference audibly.
            guard pendingResolveTopUp else { audioMeterLock.unlock(); return }
            pendingResolveTopUp = false
            let aheadFrames = framesScheduled &- framesPlayed
            let aheadMs = meterSampleRate > 0
                ? Double(aheadFrames) / meterSampleRate * 1000.0 : 0
            let deficitMs = playoutTargetMs - aheadMs
            audioMeterLock.unlock()
            if deficitMs >= Self.playoutCushionStepMs {
                backfillCushion(deficitMs: deficitMs, format: format)
            }
            return
        }
        let aheadFrames = framesScheduled &- framesPlayed
        let aheadMs = meterSampleRate > 0 ? Double(aheadFrames) / meterSampleRate * 1000.0 : 0
        if aheadMs >= playoutTargetMs {
            audioMeterLock.unlock()
            // Cushion is built - begin (or, re-prime, continue) gapless playback;
            // the already-queued buffers drain ahead of the playhead as the cushion.
            // `primed` latches ONLY on a successful start (see
            // startPlayoutAtPrimeEdge - the post-wake stopped-engine crash):
            // on failure the next packet re-enters this edge and retries.
            guard startPlayoutAtPrimeEdge() else { return }
            audioMeterLock.lock()
            primed = true
            audioMeterLock.unlock()
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
            audioMeterLock.unlock()
            guard startPlayoutAtPrimeEdge() else { return }
            audioMeterLock.lock()
            primed = true
            audioMeterLock.unlock()
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
            // Sub-step deficit / failed alloc: prime as-is - but only if
            // playback actually starts; a play failure (post-wake stopped
            // engine) leaves the machine un-primed and this cheap path
            // retries per packet. Bounded: with fill ≈ target the deficit
            // stays sub-step, so the retries never re-enter the backfill.
            guard startPlayoutAtPrimeEdge() else { return }
            audioMeterLock.lock()
            primed = true
            audioMeterLock.unlock()
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
        let targetMs = playoutTargetMs
        let route = audioRouteCache
        audioMeterLock.unlock()
        // Accounted above, scheduled here (outside the meter lock, AV-call
        // discipline): a completion in the sliver between sees fill briefly
        // overstated - harmless, and it can't mistake the moment for a drain.
        playerNode.scheduleBuffer(silence) { [weak self] in
            self?.meterCompleteOnePlayout(frames: silenceFrames, isSilence: true)
        }
        // Uniform prime edge, made exception-safe: the silence stays scheduled
        // either way (it plays when the engine returns); `primed` latches only
        // on a successful start, and the sub-step guard above makes the
        // per-packet retries cheap (fill ≈ target ⇒ no repeat backfill).
        if startPlayoutAtPrimeEdge() {
            audioMeterLock.lock()
            primed = true
            audioMeterLock.unlock()
        }
        Diag.notice(
            "audio cushion backfill +\(Int(deficitMs.rounded()))ms silence → \(Int(targetMs))ms standing fill "
            + "- no catch-up clump within the re-prime grace (steady link); route \(route)",
            "Stream")
    }
}
