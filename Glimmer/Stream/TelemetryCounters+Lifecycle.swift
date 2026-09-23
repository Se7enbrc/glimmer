//
//  TelemetryCounters+Lifecycle.swift
//
//  The LIFECYCLE of the always-live counters: the unfair-lock allocation and
//  teardown the singleton's init/deinit run, the per-session reset at a
//  session's first connect, and the narrower one an in-place reconnect takes.
//  Split out of TelemetryCounters.swift (pure move, same file-split idiom as the
//  rest of the telemetry rig) to keep that file under the length limit; see it
//  for the storage these manage and for which fields deliberately survive a
//  reset (the route-change count, the P2 state, the audio-TTF
//  last-stream-end stamp, and the thread-lifetime RT gauge).
//

import Foundation
import os

extension TelemetryCounters {

    /// Allocate + initialize every `os_unfair_lock` backing the gauge storage.
    /// Module-internal (not private) so the class's `init()` in
    /// TelemetryCounters.swift still runs it across the file split.
    func initializeGaugeLocks() {
        jitterLock.initialize(to: os_unfair_lock_s())
        inputLock.initialize(to: os_unfair_lock_s())
        rttLock.initialize(to: os_unfair_lock_s())
        vtSessionCreateLock.initialize(to: os_unfair_lock_s())
        cruiseMaxGainLock.initialize(to: os_unfair_lock_s())
        gapLock.initialize(to: os_unfair_lock_s())
        decodeStateLock.initialize(to: os_unfair_lock_s())
        fecHealthLock.initialize(to: os_unfair_lock_s())
        audioStateLock.initialize(to: os_unfair_lock_s())
        audioFirstPacketLock.initialize(to: os_unfair_lock_s())
        presentSuppressedLock.initialize(to: os_unfair_lock_s())
        decodeGatedLock.initialize(to: os_unfair_lock_s())
        pacerTickRealtimeLock.initialize(to: os_unfair_lock_s())
        reorderDispLock.initialize(to: os_unfair_lock_s())
    }

    /// Release every gauge lock. Paired with `initializeGaugeLocks()`;
    /// module-internal for the same reason - the class's `deinit` calls it.
    func deallocateGaugeLocks() {
        jitterLock.deallocate(); inputLock.deallocate()
        rttLock.deallocate(); vtSessionCreateLock.deallocate()
        cruiseMaxGainLock.deallocate()
        gapLock.deallocate()
        decodeStateLock.deallocate(); fecHealthLock.deallocate()
        audioStateLock.deallocate(); audioFirstPacketLock.deallocate()
        presentSuppressedLock.deallocate(); decodeGatedLock.deallocate()
        pacerTickRealtimeLock.deallocate(); reorderDispLock.deallocate()
    }

    /// Reset everything. Called at a session's first CONNECT-START edge
    /// (`StreamSession.anchorTelemetryConnectStart`) - BEFORE the receivers spin
    /// up, NOT at exporter start - so a warm host's mid-handshake one-shot
    /// latches (audio TTF/first-packet) can never race the reset and serve a
    /// prior session's values (the chimeric audio_ttf). (Prometheus counters are
    /// nominally never reset, but a per-session diagnostic view wants per-session
    /// totals - a scrape across a session boundary just sees a counter reset,
    /// which Prometheus handles.)
    func resetForNewSession() {
        for counter in [rfiTotal, idrRequestedTotal, backlogOverflowTotal,
                        presentStallTotal, frameLossTotal, unrecoverableFrameTotal,
                        pacerDisabledTotal, videoPacketsTotal, videoFramesTotal,
                        fecRecoveredFramesTotal, inputEventsTotal, inputBatchFlushTotal,
                        inputFlushSendBackloggedSkipTotal, inputFlushReliableBackloggedSkipTotal,
                        inputIdleToActiveTotal, bookmarkTotal,
                        cruiseBoostedBatchesTotal, cruiseIdentityBatchesTotal,
                        videoPacketsLostPreFecTotal, videoPacketsOutOfOrderTotal,
                        videoPacketsDuplicateTotal, enetRetransmitTotal,
                        ackSilenceNearMissTotal, ctrlIgnoredTotal,
                        decoderRecreateTotal, decoderRecreateFirstTotal,
                        decoderRecreateResolutionTotal, decoderRecreateColorspaceTotal,
                        staleFrameRepeatTotal, staleEmptyQueueTotal, audioNearMissTotal,
                        audioStallRecoveryTotal, audioUnderrunDeadairTotal,
                        presentGapDroughtTotal, reorderHoldExceededTotal,
                        pacerOverTargetReleaseTotal,
                        tickMissDescheduledTotal, tickMissCoalescedTotal,
                        tickMissPreemptedTotal, tickMissLinkskipTotal,
                        suppressedDropTotal, decodeGatedDropTotal, recoveryWaitDropTotal,
                        inputMotionTotal,
                        discontinuityFlushTotal,
                        audioPacketsTotal, audioPacketsLostTotal, audioFecRecoveredTotal,
                        audioFecMismatchTotal, audioUnderrunTotal, audioOverrunTotal,
                        audioTrimTotal, audioReceiveFailedTotal,
                        rumbleEventTotal, rumbleDroppedInvalidTotal,
                        // Per-socket gap-event counters.
                        videoGapOver20msTotal, videoGapOver50msTotal, videoGapOver100msTotal,
                        audioGapOver20msTotal, audioGapOver50msTotal, audioGapOver100msTotal,
                        enetGapOver20msTotal, enetGapOver50msTotal, enetGapOver100msTotal,
                        // P2 session-lifecycle counters. An in-place reconnect takes
                        // resetForReconnect instead, so these count the whole session.
                        reconnectTotal, wakeTotal,
                        idrRoundTripRequestTotal, idrRoundTripMatchedTotal,
                        corruptionHeuristicTotal] {
            counter.reset()
        }
        resetForReconnect()
        // NOTE: `p2` (the handshake timeline + disconnect reason + IDR round-trip
        // state) is DELIBERATELY NOT reset here: `anchorTelemetryConnectStart`
        // resets it itself, in the right order (reset → anchor), and keeping it
        // out of this method preserves that single-owner discipline (this method
        // and the p2 anchor are called back-to-back at the same connect edge).
        setVtSessionCreateMs(0)
        // Cruise max-gain resets to the unboosted floor (1.0), not 0.
        os_unfair_lock_lock(cruiseMaxGainLock); cruiseMaxGainValue = 1.0; os_unfair_lock_unlock(cruiseMaxGainLock)
        // Present-suppression + decode-gate gauges: a session starts with a
        // visible stream view, and the present/decode paths re-stamp these at
        // the next suppression/gate edge.
        setPresentSuppressed(false)
        setDecodeGated(false)
        // RT gauge is NOT reset here: it's a THREAD-LIFETIME fact, set once when
        // the tick thread starts. The thread is REUSED across reconnects (it never
        // re-applies/re-stamps), so clearing it here would make the gauge lie
        // inversely on every reconnect. Leave it at its thread-set value.
        // Per-type ignored-control tallies are per-session like the aggregate total.
        ctrlIgnoredPerType.reset()
        os_unfair_lock_lock(inputLock); lastInputNanosValue = 0; os_unfair_lock_unlock(inputLock)
        rumbleActivity.reset()
        os_unfair_lock_lock(decodeStateLock); decodeStateValue = nil; os_unfair_lock_unlock(decodeStateLock)
        awdlHelperState.withLock { $0 = nil }
        os_unfair_lock_lock(audioStateLock)
        audioStateValue = nil; audioBufferFillMinMsValue = .infinity
        os_unfair_lock_unlock(audioStateLock)
    }

    /// In-place reconnect, a new connection inside the same session: clear the
    /// one-shot audio latches and the per-connection link gauges, keep every total
    /// so the receipt covers the whole run.
    func resetForReconnect() {
        setRecvJitterMs(0)
        setRttMs(0)
        os_unfair_lock_lock(gapLock); packetGapValue = nil; os_unfair_lock_unlock(gapLock)
        os_unfair_lock_lock(fecHealthLock); fecHealthValue = nil; os_unfair_lock_unlock(fecHealthLock)
        // The TTF record resets; its last-stream-end stamp survives (host_idle_s).
        audioTtf.resetForNewSession()
        os_unfair_lock_lock(audioFirstPacketLock)
        audioFirstPacketMsValue = 0; audioStreamStartNanosValue = 0
        os_unfair_lock_unlock(audioFirstPacketLock)
    }
}
