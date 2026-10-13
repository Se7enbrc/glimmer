// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

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

import GlimmerEngine
import AVFoundation
import Foundation

extension AudioDecoder {

    /// Cold pre-roll opens ring consumption only at the target or scaled fallback. A live drain
    /// keeps pulling: its catch-up clump has 250 ms before bounded silence fills the deficit.
    /// Decide under the meter lock; perform lifecycle work only after releasing it.
    func maybePrime(format: AVAudioFormat, onWorker: Bool = false) {
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
                backfillCushion(deficitMs: deficitMs, format: format, onWorker: onWorker)
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
            guard startPlayoutAtPrimeEdge(allowRecovery: !onWorker) else { return }
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
            guard startPlayoutAtPrimeEdge(allowRecovery: !onWorker) else { return }
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
        backfillCushion(deficitMs: deficitMs, format: format, onWorker: onWorker)
    }

    /// Steady 1:1 arrivals cannot rebuild headroom after a drain. One bounded silence buffer
    /// closes the measured deficit after catch-up grace; jittery links normally refill before this.
    /// Trim/ceiling gates remove any later overshoot. Caller holds decode admission.
    private func backfillCushion(deficitMs: Double, format: AVAudioFormat, onWorker: Bool) {
        if silencePool == nil && !onWorker {
            silencePool = makeSilencePool(format: format)
        }
        let frames = AVAudioFrameCount((deficitMs / 1000.0) * format.sampleRate)
        // Sub-step deficits aren't worth a splice - fill is already within one
        // ratchet quantum of target. That case (and a failed allocation) primes
        // as-is rather than wedging the state machine un-primed.
        guard deficitMs >= Self.playoutCushionStepMs, frames > 0,
              let lease = silencePool?.acquire() else {
            // Sub-step deficit / failed alloc: prime as-is - but only if
            // playback actually starts; a play failure (post-wake stopped
            // engine) leaves the machine un-primed and this cheap path
            // retries per packet. Bounded: with fill ≈ target the deficit
            // stays sub-step, so the retries never re-enter the backfill.
            guard startPlayoutAtPrimeEdge(allowRecovery: !onWorker) else { return }
            audioMeterLock.lock()
            primed = true
            audioMeterLock.unlock()
            return
        }
        let silence = lease.buffer
        guard frames <= silence.frameCapacity else { lease.pool.release(lease.index); return }
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
        schedulePlayout(silence, true, lease.completion)
        // Uniform prime edge, made exception-safe: the silence stays scheduled
        // either way (it plays when the engine returns); `primed` latches only
        // on a successful start, and the sub-step guard above makes the
        // per-packet retries cheap (fill ≈ target ⇒ no repeat backfill).
        if startPlayoutAtPrimeEdge(allowRecovery: !onWorker) {
            audioMeterLock.lock()
            primed = true
            audioMeterLock.unlock()
        }
        AudioDiagnostics.notice(
            "audio cushion backfill +\(Int(deficitMs.rounded()))ms silence → \(Int(targetMs))ms standing fill "
            + "- no catch-up clump within the re-prime grace (steady link); route \(route, privacy: .private)",
            "Stream")
    }
}
