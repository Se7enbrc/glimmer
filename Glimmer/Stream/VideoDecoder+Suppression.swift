//
//  VideoDecoder+Suppression.swift
//
//  Intentional non-presentation handling: the proactive root-cause half of the
//  "rfis/idrs and backflows happen when the window isn't focused" fix.
//
//  When the stream window is backgrounded / occluded / minimized while the
//  stream keeps running (the user Cmd-Tabbed to the launcher, moved the window
//  to a second display that's asleep, etc.), the present path stops retiring
//  frames — an off-screen window's CADisplayLink stops firing and an occluded
//  AVSampleBufferVideoRenderer stops draining — so the decode backlog and the
//  pacer FIFO fill up even though the wire is perfectly healthy. The decode side
//  must NOT misread that intentional non-present backlog as packet loss and spam
//  IDR/RFI. This file owns:
//
//   * `setPresentSuppressed` — the present-suppressed state transition, with a
//     drain-to-newest on enter (no IDR) and, on exit, a flush + single-IDR
//     resync that keeps the retained newest frame for an instant repaint.
//   * the DECODE GATE (stage 2) — after `decodeGateDelaySeconds` of CONTINUOUS
//     suppression, stop feeding compressed AUs to VideoToolbox entirely
//     (decoding 4K120 at ~30% CPU for a pacer that discards every frame is
//     pure waste). Receive/depacketize/RFI and audio keep flowing untouched;
//     on resume the gate lifts unconditionally and the first fed frame is
//     forced to be an IDR via the depacketizer's existing wait-for-IDR gate.
//   * the PROACTIVE layer-stall observers (renderer requires-flush + layer
//     failed-to-decode) that reflush sub-frame, before the present watchdog.
//
//  The NON-LOSS IDR sources (decode-backlog drop-to-IDR in VideoDecoder+Decode,
//  pacing-overflow IDR in VideoDecoder+Session) are gated on `presentSuppressed`;
//  GENUINE on-wire loss detection (the depacketizer's gap detection → RFI/IDR)
//  is NEVER gated by it. See VideoDecoder.swift for the `presentSuppressed`
//  state + the observer-token storage.
//

import AppKit
import AVFoundation
import Foundation
import os

extension VideoDecoder {

    // MARK: - Intentional non-presentation (backgrounded / occluded / minimized)

    /// Flip the "presentation is intentionally suppressed" state and own the
    /// transition-edge work on each edge. Called on the main actor from the
    /// window's onBackgroundedChanged signal (key/occlusion/miniaturize):
    ///
    ///  * suppressed = true  (window orderOut'd / occluded / backgrounded):
    ///    the present path will stop retiring frames (off-screen CADisplayLink
    ///    stops firing, occluded renderer stops draining). We DON'T pause decode
    ///    — the constraint is that background / second-monitor streaming stays in
    ///    sync for an instant resume — so the FIFO would grow. We arm the pacer's
    ///    suppressed mode (each subsequent submit drops-to-newest inline, counted
    ///    as SUPPRESSED — not late — drops) and drain the existing backlog to the
    ///    freshest frame, and from now on `decodeAssembledFrame` treats a backlog
    ///    overflow as a BENIGN drop instead of a reference-break → no IDR/RFI
    ///    spam. (The pacer's own trims never request a keyframe at all.)
    ///
    ///  * suppressed = false (window re-shown / re-focused / un-occluded):
    ///    repaint cleanly instead of bursting out a stale backlog. The suppressed
    ///    period left the pacer holding exactly the NEWEST frame — keep it, so
    ///    the first tick after refocus presents the freshest pixels instantly —
    ///    then flush the renderer and request EXACTLY ONE IDR for the whole
    ///    refocus. This is the one intentional IDR per suppression episode.
    ///
    /// Idempotent: a same-value call is a no-op (we only do edge work on a real
    /// transition), so duplicate key/occlusion notifications don't double-drain
    /// or double-IDR.
    @MainActor
    func setPresentSuppressed(_ suppressed: Bool) {
        presentSuppressedLock.lock()
        let changed = _presentSuppressed != suppressed
        if changed { _presentSuppressed = suppressed }
        presentSuppressedLock.unlock()
        guard changed else { return }

        if suppressed {
            // ENTER suppression: arm the pacer's suppressed mode FIRST (a submit
            // racing the edge then drops-to-newest instead of minting an overflow
            // late-drop), then collapse the FIFO to the freshest frame so the
            // backlog can't balloon while nothing presents. Quiet — NO IDR. The
            // edge is mirrored into the Diag ring + the telemetry gauge: these
            // transitions were os.Logger-only, leaving the suppressed phase
            // invisible to the capture forensics (the "silent transition" that
            // misled a whole analysis pass chasing a zero-render mystery).
            log.notice("Present suppressed (window backgrounded/occluded) — draining FIFO to newest, IDR escalation off")
            OSSignposter.render.emitEvent("PresentSuppressed", "state=on")
            Diag.notice(
                "present suppressed (window backgrounded/occluded) — pacer holds newest frame only, IDR escalation off",
                "Stream")
            TelemetryCounters.shared.setPresentSuppressed(true)
            framePacer?.setPresentSuppressed(true)
            framePacer?.dropToNewest(reason: "present_suppressed")
            // Arm stage 2: if the window stays hidden past the gate delay,
            // stop feeding VideoToolbox too. Armed LAST so a gate firing can
            // never observe a half-entered suppression edge.
            armDecodeGateTimer()
        } else {
            // EXIT suppression: disarm the pacer's suppressed mode and KEEP the
            // retained newest frame (collapse-only — a no-op at the suppressed
            // rest depth of 1) so the first tick after refocus presents the
            // freshest pixels instantly, then repaint from a clean keyframe.
            // recoverPresentPath does flush + (rebuild-if-failed) + IDR, which is
            // exactly the clean-repaint we want — and reuses the shipped
            // self-heal path rather than forking a second one.
            log.notice("Present un-suppressed (window refocused) — newest frame retained, flush + single IDR resync")
            OSSignposter.render.emitEvent("PresentSuppressed", "state=off")
            Diag.notice(
                "present un-suppressed (window refocused) — retained newest frame presents, single IDR resync",
                "Stream")
            TelemetryCounters.shared.setPresentSuppressed(false)
            framePacer?.setPresentSuppressed(false)
            framePacer?.dropToNewest(reason: "present_resync")
            // Stand down stage 2 BEFORE the resync below: cancel a pending
            // gate (rapid alt-tab — never engaged, never costs anything) and
            // UNCONDITIONALLY lift an engaged gate. The post-gate IDR-only
            // latch stays armed across the lift; the submit boundary resolves it.
            cancelDecodeGateTimer()
            let gateWasEngaged = liftDecodeGate()
            // REFOCUS IDR DEDUPE (measured: idr_requested +2, two 'ENet IDR
            // frame requested' ~21ms apart, two keyframes ~25ms apart — the
            // gate-lift + depacketizer race). When the gate WAS
            // engaged, the post-gate resync latch already owns the refocus
            // IDR: the first post-gate AU either IS a keyframe (feeds, zero
            // requests needed) or routes `.resyncToIdr` into the
            // depacketizer's wait-for-IDR gate, which sends the one coalesced
            // request AND holds non-IDR frames until it lands — so a second
            // request from recoverPresentPath here only buys a redundant 4K
            // keyframe. On a gated exit do just the cheap renderer flush (the
            // same medicine the suppressed requires-flush observer uses) and
            // delegate the single IDR to the resync; the full
            // recoverPresentPath (flush + rebuild-if-failed + IDR) still runs
            // when no gate engaged (rapid alt-tab — no resync latch armed, so
            // this IS the one refocus IDR) or when the renderer hard-failed
            // (a bare flush can't clear .failed; the rebuild needs its IDR).
            // Loss safety: the resync request rides the depacketizer's
            // existing wait+re-request machinery, and if the IDR never decodes
            // the frame watchdog still trips on the normal post-gate envelope
            // (secondsSinceDecodeGateLifted) — no new way to get stuck.
            let rendererFailed =
                displayLayer?.sampleBufferRenderer.status == .failed
            if gateWasEngaged && !rendererFailed {
                displayLayer?.sampleBufferRenderer.flush()
            } else {
                recoverPresentPath(reason: "present_resync")
            }
        }
    }

    // MARK: - Decode gating (stage 2: stop feeding VideoToolbox while hidden)

    /// What the submit boundary should do with one assembled AU, given the
    /// gate state. Computed under `presentSuppressedLock` in
    /// `decodeGateDisposition(isIDR:)`; consumed at the very top of
    /// `decodeAssembledFrame` before any slot reservation or VT work.
    enum DecodeGateDisposition {
        /// Normal path — feed the frame to the decode pipeline.
        case feed
        /// Gated: drop the AU quietly — no IDR, no slot, no log line. Counted
        /// in `decodeGatedDropTotal` (its OWN counter: `suppressedDropTotal`
        /// means displaced PRESENT frames, not ungated decodes) because
        /// without one a gated span — fps_decoded=0, drops_suppressed flat —
        /// was indistinguishable in the NDJSON from a genuine decode wedge
        /// while hidden. The `decode_gated` gauge + the Diag NOTICE on the
        /// gate edges carry the STATE; the counter carries the volume.
        case dropQuietly
        /// First post-gate frame is NOT an IDR: return DR_NEED_IDR so the
        /// receive thread drives the depacketizer's existing wait-for-IDR
        /// recovery gate (`requestDecoderRefresh` — wait + coalesced IDR
        /// request), exactly the reference-invalidation flush the sustained
        /// backlog stall reuses. Feeding this P-frame would macroblock: its
        /// references were dropped, undecoded, during the gate.
        case resyncToIdr
    }

    /// Resolve the gate state for one assembled AU. Called on the native
    /// backend's receive thread (the same thread that owns the depacketizer,
    /// which is what makes the `.resyncToIdr` → `requestDecoderRefresh`
    /// handoff race-free: the depacketizer enters wait-for-IDR before it can
    /// process another packet). The one-shot post-gate latch is cleared on
    /// BOTH non-gated outcomes — on `.feed`-of-an-IDR because the reference
    /// chain is reset by the keyframe itself, and on `.resyncToIdr` because
    /// the wait now lives in the depacketizer, which stops emitting non-IDR
    /// frames entirely until a real one arrives.
    nonisolated func decodeGateDisposition(isIDR: Bool) -> DecodeGateDisposition {
        presentSuppressedLock.lock()
        if _decodeGated {
            presentSuppressedLock.unlock()
            // Counted, never logged: the gated-drop total is what lets a
            // zero-decode row self-label as "gated by design" vs "decode
            // wedge". Incremented OUTSIDE the suppression lock so the
            // counter's own lock never nests under it; ≤ frame rate while
            // hidden, the same budget `suppressedDropTotal` already pays.
            TelemetryCounters.shared.decodeGatedDropTotal.increment()
            return .dropQuietly
        }
        if _awaitingPostGateIdr {
            _awaitingPostGateIdr = false
            presentSuppressedLock.unlock()
            return isIDR ? .feed : .resyncToIdr
        }
        presentSuppressedLock.unlock()
        return .feed
    }

    /// Lock-guarded read of the gate flag for the frame watchdog (gated =
    /// healthy-by-design, not a decode stall). Same accessor shape as
    /// `presentSuppressed` above it in the ladder.
    nonisolated var decodeGated: Bool {
        presentSuppressedLock.lock(); defer { presentSuppressedLock.unlock() }
        return _decodeGated
    }

    /// Seconds since the decode gate last lifted; `.infinity` if no gate has
    /// ever engaged this session. The frame watchdog takes
    /// `min(secondsSinceLastDecodedFrame(), this)` so a long gated span reads
    /// as idle-since-resume instead of idle-for-the-whole-gate — the watchdog
    /// re-arms honestly FROM the resume edge (a post-gate IDR that genuinely
    /// never decodes still trips it on the normal thresholds).
    nonisolated func secondsSinceDecodeGateLifted() -> Double {
        presentSuppressedLock.lock(); defer { presentSuppressedLock.unlock() }
        guard let lifted = _decodeGateLiftedAtNanos else { return .infinity }
        return Double(DispatchTime.now().uptimeNanoseconds &- lifted) / 1_000_000_000
    }

    /// Arm (or re-arm) the gate timer on the suppress edge. A rapid alt-tab
    /// cancels it on the resume edge before it fires, so brief focus flips
    /// never gate — and therefore never need a forced-IDR resync beyond the
    /// one the suppression exit already owns.
    @MainActor
    private func armDecodeGateTimer() {
        decodeGateTimer?.cancel()
        decodeGateTimer = Task { [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(VideoDecoder.decodeGateDelaySeconds * 1_000_000_000))
            // A cancel that lands after the sleep already completed still
            // marks the task — check before engaging.
            guard !Task.isCancelled else { return }
            self?.engageDecodeGate()
        }
    }

    /// Cancel a pending gate timer. Called on the resume edge and from
    /// `teardown()`; idempotent.
    @MainActor
    func cancelDecodeGateTimer() {
        decodeGateTimer?.cancel()
        decodeGateTimer = nil
    }

    /// Gate-ON edge: the window has been continuously hidden for the full
    /// delay. From here the submit boundary drops every AU before VT sees it;
    /// the post-gate IDR-only latch arms at the same instant, under the same
    /// lock hold, so there is no window where the gate is on without the
    /// resync obligation recorded.
    @MainActor
    private func engageDecodeGate() {
        // Defensive re-checks: teardown may have raced the timer (isStreaming
        // off), and the lock-guarded suppression re-read catches a resume
        // whose cancel lost the race with an already-completed sleep. The
        // isStreaming re-read INSIDE the lock is load-bearing: handleStop
        // flips it false and then clears the gate under this same lock
        // (clearDecodeGateForConnectionStop), so a timer firing concurrently
        // with a connection stop either loses the lock race and observes
        // isStreaming false here, or wins it and has its gate cleared right
        // after — it can never re-engage the gate on a stopped connection
        // (which would re-block the teardown watchdog).
        guard isStreaming else { return }
        presentSuppressedLock.lock()
        let engage = isStreaming && _presentSuppressed && !_decodeGated
        if engage {
            _decodeGated = true
            _awaitingPostGateIdr = true
        }
        presentSuppressedLock.unlock()
        guard engage else { return }
        log.notice("Decode gated (hidden past gate delay) — AUs dropped before VideoToolbox; receive/RFI + audio continue")
        OSSignposter.decode.emitEvent("DecodeGate", "state=on")
        Diag.notice("decode gated after 2s hidden; receive+audio continue", "Stream")
        // Mirror the edge into the telemetry gauge (the setPresentSuppressed
        // discipline): the per-second record self-labels a gated span without
        // Diag cross-correlation — the third hidden-window state was the one
        // the NDJSON couldn't see.
        TelemetryCounters.shared.setDecodeGated(true)
    }

    /// Gate-OFF edge: UNCONDITIONAL on resume (never a permanent give-up).
    /// Stamps the lift instant for the frame watchdog's idle floor and leaves
    /// `_awaitingPostGateIdr` armed — the submit boundary, not this edge,
    /// decides whether the first post-gate frame feeds (it's the resync IDR)
    /// or flushes the depacketizer to wait-for-IDR. Returns whether a gate was
    /// actually engaged, so the exit edge can route the single refocus IDR to
    /// the right owner (see the dedupe in `setPresentSuppressed`).
    @MainActor
    @discardableResult
    private func liftDecodeGate() -> Bool {
        presentSuppressedLock.lock()
        let wasGated = _decodeGated
        if wasGated {
            _decodeGated = false
            _decodeGateLiftedAtNanos = DispatchTime.now().uptimeNanoseconds
        }
        presentSuppressedLock.unlock()
        guard wasGated else { return false }
        log.notice("Decode gate lifted on refocus — resyncing to next IDR")
        OSSignposter.decode.emitEvent("DecodeGate", "state=off")
        Diag.notice("decode gate lifted on refocus — resync to next IDR", "Stream")
        // Gauge mirror of the lift edge (see the engage edge for the WHY).
        TelemetryCounters.shared.setDecodeGated(false)
        return true
    }

    /// Gate-OFF edge for the CONNECTION-STOP path. `NativeBackend.stopConnection`
    /// reaches this through the sink's `stop()` (`handleStop`), which runs for
    /// BOTH teardown directions: StreamSession.stop() and a HOST-INITIATED
    /// terminate (enet.onTerminated → stopConnection, where no stop() has run
    /// yet). The second direction is why this must exist: with the window hidden
    /// past the gate delay, an engaged gate made the 1Hz frame watchdog bail on
    /// every tick — but that watchdog's hard trip is the ONLY route from a host
    /// terminate to a real StreamSession.stop(). A gate only the refocus edge
    /// could lift (an edge that never comes while the user is away) left a
    /// zombie session: isStreaming latched true, the keep-awake assertion held
    /// indefinitely, the launcher pulsing "Streaming" at a dead host. Clearing
    /// the gate here unblocks the watchdog; stamping the lift instant re-arms
    /// its idle floor from THIS edge, so teardown lands on the normal post-gate
    /// envelope (hard trip ≤ frameWatchdogTimeout) — no refocus required, and no
    /// premature trip off the stale gated-span idle. `_awaitingPostGateIdr` is
    /// dropped too: no post-gate frame can arrive on a stopped connection.
    /// Callable from any thread (the backend's stop path) — all lock-guarded.
    nonisolated func clearDecodeGateForConnectionStop() {
        presentSuppressedLock.lock()
        let wasGated = _decodeGated
        if wasGated {
            _decodeGated = false
            _decodeGateLiftedAtNanos = DispatchTime.now().uptimeNanoseconds
        }
        _awaitingPostGateIdr = false
        presentSuppressedLock.unlock()
        guard wasGated else { return }
        log.notice("Decode gate cleared on connection stop — frame watchdog owns teardown from here")
        OSSignposter.decode.emitEvent("DecodeGate", "state=off")
        Diag.notice("decode gate cleared on connection stop — teardown watchdog unblocked", "Stream")
        // Gauge mirror of the clear edge (the liftDecodeGate discipline).
        TelemetryCounters.shared.setDecodeGated(false)
    }

    // MARK: - Proactive layer-stall observers

    /// Subscribe to the layer's PROACTIVE stall signals so an occlusion- or
    /// background-triggered renderer LATCH reflushes the instant it happens —
    /// sub-frame, before the 20Hz present watchdog would catch it. Two signals,
    /// both via NotificationCenter (cleaner than KVO here — the property KVO on
    /// the macOS-15-deprecated layer property warns, and the renderer ships
    /// dedicated did-change notifications):
    ///
    ///  * `AVSampleBufferVideoRenderer
    ///    .requiresFlushToResumeDecodingDidChangeNotification` on the renderer we
    ///    enqueue onto — fires when its `requiresFlushToResumeDecoding` flips.
    ///  * `.AVSampleBufferDisplayLayerFailedToDecode` on this layer — fired when
    ///    a sample fails to decode.
    ///
    /// On the requires-flush latch (when it's actually true) we run
    /// `recoverPresentPath` (flush; rebuild-if-failed; IDR) immediately —
    /// EXCEPT while presentation is suppressed (window hidden), where it gets a
    /// CHEAP flush WITHOUT the IDR (the single clean-repaint IDR is owned by the
    /// refocus resync, so we don't waste host bandwidth on an IDR for a layer
    /// nobody is looking at). A failedToDecode is a genuine glitch that won't
    /// clear itself, so it always runs the full recovery.
    ///
    /// Idempotent: clears any prior observers first, so a layer rebuild (attach
    /// called again with a fresh layer) re-targets cleanly without stacking.
    func installLayerStallObservers(on layer: AVSampleBufferDisplayLayer) {
        removeLayerStallObservers()

        let nc = NotificationCenter.default
        let renderer = layer.sampleBufferRenderer

        layerStallObservers.append(
            nc.addObserver(
                forName: AVSampleBufferVideoRenderer
                    .requiresFlushToResumeDecodingDidChangeNotification,
                object: renderer,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    // Re-read the renderer through the live layer (don't capture
                    // the non-Sendable renderer in this @Sendable closure); the
                    // notification only fires for the renderer we registered on.
                    guard let self,
                          let renderer = self.displayLayer?.sampleBufferRenderer,
                          renderer.requiresFlushToResumeDecoding
                    else { return }
                    if self.presentSuppressed {
                        // Hidden: cheap flush only, no IDR (resync owns the IDR).
                        OSSignposter.render.emitEvent("LayerRequiresFlush", "suppressed=true")
                        renderer.flush()
                    } else {
                        OSSignposter.render.emitEvent("LayerRequiresFlush", "suppressed=false")
                        self.recoverPresentPath(reason: "requires_flush")
                    }
                }
            })

        layerStallObservers.append(
            nc.addObserver(
                forName: .AVSampleBufferDisplayLayerFailedToDecode,
                object: layer,
                queue: .main
            ) { [weak self] note in
                // Flatten the non-Sendable Notification into a plain String here
                // (the observer already runs on `.main`), so nothing non-Sendable
                // crosses into the MainActor.assumeIsolated body.
                let errDesc = (note.userInfo?[
                    AVSampleBufferDisplayLayerFailedToDecodeNotificationErrorKey]
                    as? NSError)?.localizedDescription ?? "unknown"
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.log.warning(
                        "Layer failedToDecode (\(errDesc, privacy: .public)) — proactive present-path self-heal")
                    OSSignposter.render.emitEvent("LayerFailedToDecode", "")
                    self.recoverPresentPath(reason: "failed_to_decode")
                }
            })
    }

    /// Tear down the proactive layer observers. Called from `teardown()` and
    /// before re-installing onto a rebuilt layer.
    func removeLayerStallObservers() {
        let nc = NotificationCenter.default
        for obs in layerStallObservers { nc.removeObserver(obs) }
        layerStallObservers.removeAll()
    }
}
