//
//  VideoDecoder+API.swift
//
//  Public control surface for the decoder: stats-overlay toggle + snapshot,
//  negotiated-bitrate / audio-config labels, teardown, HDR engagement +
//  metadata refresh, display-layer attach, and backend wiring. Split out of
//  VideoDecoder.swift to keep each unit focused; see that file for stored state.
//

import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import os

extension VideoDecoder {

    public func toggleStatsOverlay() {
        statsOverlayEnabled.toggle()
    }

    /// Read the current accumulator state for the stats overlay. Returns a
    /// `StreamStatsSnapshot` with everything we can compute locally; the
    /// caller (StreamSession's overlay timer) augments it with
    /// `LiGetEstimatedRttInfo` data before handing it to the overlay layer.
    ///
    /// Safe to call from the main actor at any time - the underlying
    /// `StatsCollector` uses atomic counters + an internal lock for the
    /// decode-time EMA, so it tolerates the cross-thread reads.
    /// `minWindowSeconds` is forwarded to `StatsCollector.snapshot` so the
    /// overlay can tick faster than the FPS averaging window without making the
    /// FPS rows noisy - the collector keeps the FPS/bitrate/cadence fields on a
    /// `minWindowSeconds`-wide average while the live latency gauges refresh
    /// every call. Defaults to 0 (reset-every-read) to preserve every existing
    /// caller's behaviour.
    public func statsSnapshot(minWindowSeconds: Double = 0) -> StreamStatsSnapshot {
        var snap = statsCollector.snapshot(minWindowSeconds: minWindowSeconds)
        // Augment with stream-level values we know on the main actor.
        if streamFps > 0 {
            snap.hostFps = Double(streamFps)
        }
        if negotiatedBitrateKbps > 0 {
            snap.negotiatedBitrateMbps = Double(negotiatedBitrateKbps) / 1000.0
        }
        // Renderer drops are tracked but not zeroed inside the snapshot's
        // sliding window (drops are session-cumulative, not per-tick); read
        // the raw counter and surface it. The overlay formatter omits the
        // row when zero, so a healthy stream doesn't clutter on this.
        snap.rendererBackpressureDrops = statsCollector.backpressureDropCount()
        // Absolute decoder-side drop count for the three-way drops-by-cause line
        // (the percentage alone can't show the D/B/L breakdown). Same raw counter
        // the telemetry exporter reads.
        snap.decoderDropCount = statsCollector.decoderDropCount()
        // Audio config - picked at session start from
        // AudioConfig.bestForCurrentOutput(); nil before session start.
        if let audio = activeAudioConfigLabel {
            snap.audioConfigDescription = audio
        }
        // Drop a marker on the OS-signpost timeline so a profile run can
        // correlate the stats overlay text with timeline state. Cheap -
        // the snapshot tick is 2 Hz, well below any signpost-rate concern.
        OSSignposter.decode.emitEvent(
            "StatsSnapshot",
            """
            decodeMs=\(snap.avgDecodeTimeMs ?? 0, privacy: .public) \
            renderedFps=\(snap.renderedFps ?? 0, privacy: .public) \
            droppedPct=\(snap.decoderDroppedPercent ?? 0, privacy: .public)
            """)
        return snap
    }

    /// Stash the negotiated bitrate so `statsSnapshot()` can surface it
    /// alongside the measured bitrate. Called by `StreamSession.start` right
    /// after it builds the `STREAM_CONFIGURATION`. Optional - if the caller
    /// never sets it, the overlay just shows the measured value.
    public func setNegotiatedBitrateKbps(_ kbps: Int) {
        negotiatedBitrateKbps = kbps
    }

    /// Stash the live audio-config label so `statsSnapshot()` can surface
    /// it in the overlay. Called by `StreamSession.start` right after it
    /// picks the AudioConfig. The value is the user-facing display string
    /// from `AudioConfig.displayLabel`, not the underlying channel bitmask.
    public func setActiveAudioConfigLabel(_ label: String) {
        activeAudioConfigLabel = label
    }

    /// Per-frame counters. Created in init, drained on teardown. Touched
    /// from the moonlight receive thread (submit byte count, received-frame
    /// count), the VT decode queue (decode-time measurements, dropped-frame
    /// count, decoder-output FPS), and the main actor (snapshot reads from
    /// the overlay timer). The type is `@unchecked Sendable` over an
    /// internal `os_unfair_lock`, so it crosses isolation boundaries safely.
    ///
    /// `nonisolated` because the static VT callback closure invokes
    /// `recordDecodeComplete` from the decode queue; without it, Swift 6's
    /// strict-concurrency check would trap at runtime crossing the class's
    /// @MainActor isolation.

    /// Public proxies for StreamSession's frame-arrival watchdog. The
    /// watchdog gates on `secondsSinceLastDecodedFrame()` - "did VT produce
    /// an output frame" - so a host sending us packets we can't decode
    /// (corrupted bitstream, missing IDR, AV1-on-no-AV1-hardware) trips the
    /// watchdog instead of the user staring at a black screen while the log
    /// reports healthy reception. `secondsSinceLastReceivedFrame()` is
    /// exposed alongside so the watchdog can distinguish "host gone silent"
    /// (both stalls) from "host sending but we can't decode" (only decode
    /// stalls) and pick the appropriate recovery.
    public nonisolated func secondsSinceLastDecodedFrame() -> Double {
        statsCollector.secondsSinceLastDecodedFrame()
    }

    public nonisolated func secondsSinceLastReceivedFrame() -> Double {
        statsCollector.secondsSinceLastReceivedFrame()
    }

    /// Seconds since a frame last reached the renderer (the MODE-AGNOSTIC present
    /// clock). Unlike `pacingLiveness()` - which is nil once the pacer is disabled
    /// and so blinds the watchdog on the direct-enqueue path - this advances on
    /// every `renderer.enqueue` in BOTH modes. The present-path watchdog uses it
    /// to detect a screen freeze (decode healthy, nothing presented) regardless
    /// of whether pacing is up.
    public nonisolated func secondsSinceLastPresentedFrame() -> Double {
        statsCollector.secondsSinceLastPresent()
    }

    /// Current in-flight decode backlog (frames submitted to VT but not yet
    /// output). Lock-guarded read of the same counter the receive-thread backlog
    /// gate maintains; safe from any thread. Surfaced ONLY by the opt-in
    /// telemetry exporter.
    public nonisolated func inFlightDecodeBacklog() -> Int {
        inFlightDecodeLock.lock(); defer { inFlightDecodeLock.unlock() }
        return inFlightDecodes
    }

    // MARK: - Telemetry accessors (opt-in exporter, off the main actor)
    //
    // The telemetry exporter runs on its own background queue and needs the same
    // performance numbers the overlay shows, read WITHOUT hopping to the main
    // actor. The StatsCollector + FramePacer are both `@unchecked Sendable` with
    // their own locks, so these reads are safe from any thread. They reuse the
    // StatsCollector's EXISTING lock - no second hot-path lock is added.

    /// Raw collector snapshot (decode/pacing/drop counters). Same call the
    /// overlay's `statsSnapshot()` wraps, minus the MainActor-only augmentation.
    /// `StreamStatsSnapshot` is public, so this one can be too. The rest return
    /// module-internal types (`FramePacer.LivenessSnapshot`) and stay internal -
    /// the only caller is StreamSession, in this module.
    public nonisolated func telemetryStatsSnapshot() -> StreamStatsSnapshot {
        var snap = statsCollector.snapshot()
        // Surface the negotiated bitrate ceiling so the exporter can publish the
        // goodput-vs-ceiling (P1) signal. The MainActor `statsSnapshot()` augments
        // this for the overlay; the telemetry path is nonisolated, so we read the
        // session-constant slot directly (set once at session start, then read-only
        // - `nonisolated(unsafe)` for exactly this cross-thread read).
        if negotiatedBitrateKbps > 0 {
            snap.negotiatedBitrateMbps = Double(negotiatedBitrateKbps) / 1000.0
        }
        return snap
    }
    /// RTT / ENet health through the LIVE backend slot (re-pointed by
    /// `setBackend` on a silent reconnect) - so the overlay + exporter never read
    /// a dead pre-reconnect backend (the by-value-capture staleness bug).
    nonisolated func telemetryEstimatedRtt() -> (rttMs: Double, varianceMs: Double)? { backend?.estimatedRtt() }
    nonisolated func telemetryEnetHealth()
        -> (sentReliable: Int, oldestUnackedMs: UInt32, sinceLastAckMs: UInt32)? { backend?.enetHealth() }
    nonisolated func telemetryDecoderDrops() -> UInt64 { statsCollector.decoderDropCount() }
    nonisolated func telemetryBackpressureDrops() -> UInt64 { statsCollector.backpressureDropCount() }
    nonisolated func telemetryPresentationLateDrops() -> UInt64 {
        statsCollector.presentationLateDropCount()
    }
    nonisolated func telemetryPresentationGaps() -> UInt64 {
        statsCollector.presentationGapCount()
    }
    /// Pacer present-side liveness (adaptive depth, queue depth) for the
    /// exporter; nil when pacing isn't up. `livenessSnapshot()` is lock-guarded.
    nonisolated func telemetryPacingLiveness() -> FramePacer.LivenessSnapshot? {
        framePacer?.livenessSnapshot()
    }
    /// Per-second display-refresh window (min/avg/max derived Hz + change marker)
    /// for the exporter; nil when pacing isn't up. RESET-ON-READ - only the 1Hz
    /// exporter may call this (see `FramePacer.refreshWindowSnapshot`).
    nonisolated func telemetryRefreshWindow() -> FramePacer.RefreshWindowSnapshot? {
        framePacer?.refreshWindowSnapshot()
    }

    /// One main-actor PRESENT/DISPLAY probe for the opt-in telemetry sampler
    /// (P1): the live EDR headroom on the compositing screen, HDR-engaged state,
    /// the screen name, and the panel's ProMotion / max-refresh capability. All
    /// are main-actor-isolated (NSScreen / AVSampleBufferDisplayLayer), so this is
    /// `@MainActor`; the `DisplayTelemetry` sampler calls it from a MAIN-queue 1Hz
    /// timer that exists ONLY on the gate-on path - never a hot path. Returns nil
    /// before the layer is bound to a screen (nothing to probe yet).
    @MainActor
    func telemetryDisplayProbe() -> DisplayProbe? {
        // Resolve the screen the stream actually composites on (the layer's host
        // view's window's screen), falling back to the main screen. Same walk
        // `displayEDRHeadroom()` uses, kept local so the probe is one read.
        let view = displayLayer?.delegate as? NSView
        guard let screen = view?.window?.screen ?? NSScreen.main else { return nil }
        let edr = Double(screen.maximumExtendedDynamicRangeColorComponentValue)
        let maxFps = screen.maximumFramesPerSecond
        return DisplayProbe(
            edrHeadroom: edr,
            hdrEngaged: isHDRActive,
            screenName: screen.localizedName,
            proMotionCapable: maxFps > 60,
            maxRefreshHz: maxFps)
    }

    /// Tear down the decode + display pipeline from the main actor. Safe to
    /// call more than once. After this returns the decoder will refuse to
    /// submit further frames, the VTDecompressionSession is invalidated,
    /// the display layer is flushed, and our reference to it dropped so
    /// the window can be closed cleanly without a frozen final frame.
    ///
    /// Complements (and is idempotent with) the handleCleanup path that the
    /// native backend invokes via the decoder-renderer `cleanup` sink - we
    /// call it from StreamSession.stop() to guarantee teardown order even when
    /// the backend defers cleanup or has already been stopped.
    public func teardown() {
        // Refuse further frame submissions immediately. Set before touching
        // session state so anything in flight on the decode queue bails out.
        isStreaming = false

        // Stand down the hidden-window decode gate: cancel a pending gate
        // timer (its task must not fire against a dead session) and clear the
        // gate flags. Pure state hygiene - the submit boundary is already
        // closed by isStreaming=false above, and the decoder is one-shot, but
        // a cancelled timer can resolve after teardown and must find nothing
        // to do (engageDecodeGate's isStreaming guard is the second lock).
        cancelDecodeGateTimer()
        presentSuppressedLock.lock()
        _decodeGated = false
        _awaitingPostGateIdr = false
        presentSuppressedLock.unlock()

        // Stop the frame pacer FIRST: invalidate its CADisplayLink and drain
        // its jitter buffer so no further paced present can fire at the layer
        // we're about to flush + drop below. `stop()` is idempotent and flips
        // the pacer's own `running` gate, so a tick already dispatched to its
        // serial queue no-ops. Drop our reference after.
        framePacer?.stop()
        framePacer = nil

        // Drain any in-flight decode operations before invalidating the
        // session - VTDecompressionSessionWaitForAsynchronousFrames blocks
        // until pending decodes either complete or are flushed.
        //
        // Also clear every HDR-related cache here. Without this, the next
        // session inherits stale mastering-display / content-light-level /
        // last-attached-CGColorSpace state and the first few frames of an
        // SDR session after an HDR session render through PQ until the
        // first colorspace change is detected. Symptom: SDR title screen
        // flashes washed-out on session restart.
        decodeQueue.sync { [weak self] in
            guard let self else { return }
            if let session = self.decompressionSession {
                VTDecompressionSessionWaitForAsynchronousFrames(session)
                VTDecompressionSessionInvalidate(session)
                self.decompressionSession = nil
                self.releaseOutputCallbackRefcon()
            }
            self.formatDescription = nil
            self.cachedHDRFormatDescription = nil
            self.spsData = nil
            self.ppsData = nil
            self.vpsData = nil
            // HDR caches: clear so the next session starts cold.
            self.cachedMDCV = nil
            self.cachedContentLightLevel = nil
            self.lastColorSpaceKey = nil
            self.lastColorSpace = nil
            self.hdrEnabled = false
            self.didLogFirstPixelBufferProbe = false
            self.didConfigureLayerOnce = false
            self.didFireFirstDecodedFrame = false
        }

        // Flush queued-but-unpresented buffers, but KEEP the currently
        // displayed frame (removingDisplayedImage: false). StreamWindow.close()
        // fades the window out and only then removes the displayed image, so
        // the fade lands on the real last frame instead of an already-blanked
        // window. Blanking here (removingDisplayedImage: true) is what made the
        // exit fade imperceptible. macOS 15+ requires going through
        // `sampleBufferRenderer`.
        if let renderer = displayLayer?.sampleBufferRenderer {
            renderer.flush(removingDisplayedImage: false) { }
        }

        // Tear down the proactive layer observers (KVO + failedToDecode) before
        // dropping the layer - they retain a closure that touches the renderer,
        // and an observation outliving the layer it watches is a leak.
        removeLayerStallObservers()

        // Drop the layer reference so a stray late-arriving frame can't
        // enqueue onto a layer the window has already torn down.
        displayLayer = nil

        // No bridging-pointer cleanup needed here - the backend callbacks
        // resolve us through StreamBridgeContext.current (weak). When this
        // VideoDecoder dies the weak ref nils out and any late callback
        // short-circuits at the bridge's weak load.
    }

    /// Wired from the backend's host HDR-mode callback (control 0x010e).
    /// Pulls the latest mastering-display + content-light values from the host
    /// via `backend.hdrMetadata()` and stashes them so the next CMFormatDescription
    /// rebuild can attach them. When HDR drops, the cached metadata is
    /// cleared and the next frame's format-description rebuild will
    /// recreate without HDR extensions.
    public func setHDR(enabled: Bool) {
        log.info("HDR mode: \(enabled)")
        let modeChanged = hdrEnabled != enabled
        hdrEnabled = enabled

        // Snapshot prior metadata so we can detect dynamic mid-stream HDR
        // metadata refreshes. Sunshine/GFE may resend setHdrMode(true) with
        // updated MDCV/MaxCLL when the game changes its EOTF (or when the
        // host display is hot-swapped). We honor the new metadata without
        // tearing down the layer; the next enqueued sample will pick it up
        // through the rebuilt format description.
        let priorMDCV = cachedMDCV
        let priorCLL = cachedContentLightLevel

        if enabled {
            refreshHDRMetadataFromHost()
        } else {
            cachedMDCV = nil
            cachedContentLightLevel = nil
        }

        let metadataChanged =
            priorMDCV != cachedMDCV || priorCLL != cachedContentLightLevel

        // Invalidate the cached HDR format description so the next decoded
        // frame rebuilds it with current metadata (and toggles colorspace
        // PQ ↔ non-PQ as needed).
        if modeChanged || metadataChanged {
            decodeQueue.async { [weak self] in
                self?.cachedHDRFormatDescription = nil
            }
            configureLayerColorspace()
        }
    }

    /// Force a re-fetch of `LiGetHdrMetadata` and rebuild the format
    /// description on the next frame. Useful when the host signals a
    /// metadata refresh (e.g. the user drags the game window between two
    /// HDR displays of different peak luminance).
    public func refreshHDRMetadata() {
        guard hdrEnabled else { return }
        refreshHDRMetadataFromHost()
        decodeQueue.async { [weak self] in
            self?.cachedHDRFormatDescription = nil
        }
    }

    /// Attach the OS display layer this decoder enqueues sample buffers
    /// onto. Must be called from the main actor before the stream starts so
    /// that the layer exists by the time `setup()` runs on a moonlight
    /// worker thread. Also called by the present-path self-heal's rebuild hook
    /// when a hard-failed renderer is swapped for a fresh layer - so it
    /// re-installs the proactive layer observers onto the new layer.
    public func attach(to displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        // Install the proactive layer-stall observers (renderer requires-flush +
        // layer failed-to-decode) onto the new layer. Lives in
        // VideoDecoder+Suppression.swift alongside the present-suppression state.
        installLayerStallObservers(on: displayLayer)
    }

    /// Inject the streaming engine. Called by StreamSession on the main actor
    /// right after `attach(to:)` and before the stream starts, so IDR requests
    /// (decode queue) and HDR-metadata pulls (main actor) route through the
    /// protocol. Set-once before any backend callback fires.
    public func setBackend(_ backend: StreamingBackend) {
        self.backend = backend
    }

    // The frame-pacer bring-up (`startPacing` and the `pacing*` control
    // surface), the paced present site (`presentFrame`), and the present-path
    // self-heal (`recoverPresentPath` + its escalation steps) live in
    // VideoDecoder+Pacing.swift, split out to keep this file under the length
    // limit.
}
