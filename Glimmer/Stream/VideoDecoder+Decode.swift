//
//  VideoDecoder+Decode.swift
//
//  Decode pipeline lifecycle (setup/start/stop/cleanup) and frame submission:
//  the native backend's submit-decode-unit entry, depacketized-frame assembly,
//  and the path into VideoToolbox. Split out of VideoDecoder.swift to keep each
//  unit focused; see that file for the decoder's stored state.
//

import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import os

extension VideoDecoder {

    // MARK: - Lifecycle

    nonisolated func handleSetup(
        videoFormat: Int32, width: Int32, height: Int32, redrawRate: Int32
    ) -> Int32 {
        streamVideoFormat = videoFormat
        streamWidth = width
        streamHeight = height
        streamFps = redrawRate

        // FPS-SCALE the in-flight decode pool now that we know the frame rate. The
        // bound is a TIME budget (~250ms) / ceiling (~375ms), not a fixed frame
        // count — a fixed 30/45 is 1s/1.5s of buffered latency at 30fps. Floors of
        // 15/22 keep enough slots to ride a VPN arrival burst on a low-fps stream.
        // (See `maxInFlightDecodes` in VideoDecoder.swift for the full rationale.)
        let fps = max(1, Int(redrawRate))
        maxInFlightDecodes = max(15, Int(0.25 * Double(fps)))
        maxInFlightDecodeCeiling = max(22, Int(0.375 * Double(fps)))

        // Verify the codec is HW-decodable. AV1 needs macOS 13+ and Apple
        // Silicon (M3 family and up on Mac, plus some M2 Pro/Max SKUs).
        if (videoFormat & StreamProtocol.VIDEO_FORMAT_MASK_H264) != 0 {
            if !VTIsHardwareDecodeSupported(kCMVideoCodecType_H264) {
                log.error("No HW H.264 decode")
                return -1
            }
        } else if (videoFormat & StreamProtocol.VIDEO_FORMAT_MASK_H265) != 0 {
            if !VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) {
                log.error("No HW HEVC decode")
                return -1
            }
        } else if (videoFormat & StreamProtocol.VIDEO_FORMAT_MASK_AV1) != 0 {
            if !VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1) {
                log.error("No HW AV1 decode")
                return -1
            }
        } else {
            log.error("Unknown video format: \(String(videoFormat, radix: 16))")
            return -1
        }

        log.info(
            "Decoder setup: format=\(String(videoFormat, radix: 16)) \(width)x\(height) @ \(redrawRate)fps"
        )
        return 0
    }

    nonisolated func handleStart() {
        log.info("Stream starting")
        isStreaming = true
        // Stats: zero out the counters so the very first reading the overlay
        // shows reflects "this session", not residue from a previous stream
        // (the VideoDecoder is one-shot, but the collector's reset() is also
        // what initializes the EMA's "have we seen a frame yet" state).
        statsCollector.reset()
        // Configure the display layer's colorspace + EDR engagement ONCE
        // at stream start, based on the negotiated stream format. The
        // AVSampleBufferDisplayLayer takes care of pacing internally — no
        // display link needed on our side.
        Task { @MainActor [weak self] in
            self?.configureLayerColorspace()
        }
    }

    nonisolated func handleStop() {
        log.info("Stream stopping")
        isStreaming = false
        // ZOMBIE-SESSION GUARD: on a HOST-INITIATED terminate this stop (via
        // stopConnection's sink-stop) runs with NO StreamSession.stop() yet —
        // an engaged hidden-window decode gate would otherwise block the frame
        // watchdog (the only route to a real stop()) forever. See the helper.
        clearDecodeGateForConnectionStop()
    }

    nonisolated func handleCleanup() {
        log.info("Decoder cleanup")
        decodeQueue.sync { [weak self] in
            guard let self else { return }
            if let session = self.decompressionSession {
                VTDecompressionSessionInvalidate(session)
                self.decompressionSession = nil
                self.releaseOutputCallbackRefcon()
            }
            self.formatDescription = nil
            self.cachedHDRFormatDescription = nil
            self.spsData = nil
            self.ppsData = nil
            self.vpsData = nil
            // Reset the backlog counter: the session is gone, so no further VT
            // output callbacks will fire to drain whatever was in flight. This
            // runs on the serial decodeQueue after any already-queued async
            // decode block, so the count reflects only frames VT may still be
            // holding — which invalidate above just discarded.
            self.inFlightDecodeLock.lock()
            self.inFlightDecodes = 0
            self.inFlightDecodeLock.unlock()
        }
    }

    // MARK: - Submit

    /// One frame's worth of decode inputs, captured on the receive thread and
    /// carried into the async decode block as a single value (keeps the helper
    /// signatures small and the closure capture explicit). `needsParamRebuild`
    /// is computed up front on the receive thread because it reads
    /// `decompressionSession`.
    struct PendingDecode {
        let pictureData: Data
        let newSps: Data?
        let newPps: Data?
        let newVps: Data?
        let needsParamRebuild: Bool
        let isIDR: Bool
        let rtpTimestamp: UInt32
        let totalLength: Int32
    }

    /// Shared decode core, reached by the Swift-native VideoSink path
    /// (`submitDecodeUnit(_:)`). It takes the already-walked parameter sets
    /// + concatenated picture data and runs the param-rebuild → sample-build →
    /// VT decode pipeline on the serial `decodeQueue`. Keeping this one method
    /// authoritative lets the native backend run a single, well-tested VT
    /// state-machine (serial-queue serialization, format-desc rebuild on IDR,
    /// AVCC conversion for H.264/HEVC, raw OBU for AV1) without duplicating it.
    /// Mirrors VideoDepacketizer.c reassembleFrame → submitDecodeUnit
    /// semantics.
    ///
    /// THREADING — the whole VT pipeline (param rebuild, sample build, decode
    /// submit) is dispatched to `decodeQueue` ASYNCHRONOUSLY. The caller is
    /// the native backend's receive/depacketize thread, and it must NEVER block on
    /// VideoToolbox: if it did, recvfrom would stall behind VT, the kernel
    /// socket buffer would back up, and frames would be serviced in bursts (the
    /// exact 4K240 chug this fix removes). This matches moonlight-common-c's
    /// dedicated decoder thread pulling from a queue fed by the receive thread
    /// (VideoStream.c VideoRecv/VideoDec). Because `decodeQueue` is SERIAL, the
    /// async blocks run in strict submission order — param-set rebuilds and the
    /// frames that follow them stay correctly sequenced; nothing is reordered.
    ///
    /// RETURN VALUE — with the decode now async, the synchronous return can no
    /// longer reflect VT decode success (that's known only later, in the output
    /// callback). It returns DR_OK in the steady path. The need-IDR signal is
    /// routed ASYNCHRONOUSLY instead, via `backend?.requestIdrFrame()`, from
    /// every failure site that can no longer be reported through the return:
    ///   * decode-backlog SUSTAINED stall (transient bursts are absorbed; only a
    ///     genuine stall drops the new frame — see `reserveDecodeSlot`),
    ///   * parameter-set rebuild / session-create failure,
    ///   * sample-buffer build failure,
    ///   * inline VTDecompressionSessionDecodeFrame rejection.
    /// `backend?.requestIdrFrame()` is the same thread-safe IDR route the VT
    /// output callback / renderer-failed path already use; it pushes onto the
    /// control channel's own mutex-guarded queue, so calling it off the decode
    /// queue is safe and never blocks the receive thread. The one exception we
    /// keep synchronous is the backlog-stall drop itself: we additionally return
    /// DR_NEED_IDR so the depacketizer drops its NAL state for the discarded
    /// frame immediately, mirroring moonlight's drop-on-overflow.
    nonisolated func decodeAssembledFrame(
        pictureData: Data, newSps: Data?, newPps: Data?, newVps: Data?,
        isIDR: Bool, rtpTimestamp: UInt32, totalLength: Int32
    ) -> Int32 {
        // ---- Hidden-window decode gate (suppression stage 2 — see the
        // `_decodeGated` doc in VideoDecoder.swift). While the window has been
        // hidden past the gate delay we stop feeding AUs to VideoToolbox at
        // all — decoding 4K120 (~30% CPU) for a pacer that discards every
        // frame is pure waste. The drop is QUIET: no slot reserved, no counter
        // (these frames were headed for the suppressed pacer's drop-to-newest
        // anyway); the depacketizer/RFI bookkeeping upstream keeps flowing
        // untouched, so the wire never sees the gate.
        //
        // ARTIFACT SAFETY — the same invariant as the backlog drop below: a
        // silent sink-side drop is only safe because nothing non-IDR is fed
        // after the gap. `.resyncToIdr` returns DR_NEED_IDR exactly once when
        // the first post-gate frame is a P-frame, driving the depacketizer
        // into its EXISTING wait-for-IDR recovery gate (requestDecoderRefresh
        // — the same flush-to-IDR the sustained-stall path uses, IDR request
        // coalesced by the control channel with the resume edge's resync), so
        // no reference-broken P-frame can reach VT. A first post-gate frame
        // that already IS the resync IDR feeds straight through.
        switch decodeGateDisposition(isIDR: isIDR) {
        case .feed:
            break
        case .dropQuietly:
            return StreamProtocol.DR_OK
        case .resyncToIdr:
            return StreamProtocol.DR_NEED_IDR
        }

        // ---- Burst-absorbing decode backlog (see `maxInFlightDecodes`).
        // Checked + reserved on the receive thread BEFORE we dispatch any work.
        // The bound is deep enough (~250ms at 120fps) that a transient VPN
        // arrival burst is absorbed by VT's async pipeline rather than tripping
        // it — that's the hitch this pass removes.
        //
        // ARTIFACT-SAFETY INVARIANT: dropping a not-yet-decoded P-frame here
        // WITHOUT flushing-to-IDR would orphan the reference chain (the
        // white/purple corruption fixed in an earlier build), because the depacketizer
        // already considers this frame DELIVERED — it assembled it off the wire
        // and handed it to us, so its on-the-wire loss detection
        // (`depacketizerDetectedFrameLoss`) will NOT see the gap a sink-side drop
        // creates. So there is no safe SILENT pre-decode drop: the only two
        // artifact-safe outcomes are (1) reserve the slot and decode the frame,
        // or (2) drop it AND flush-to-IDR so the depacketizer stops emitting
        // reference-broken frames until the next real IDR.
        //
        // `reserveDecodeSlot()` therefore returns only those two outcomes. It
        // ABSORBS a burst by reserving past the nominal bound while VT is
        // actively draining (recent decode output), up to a hard ceiling that
        // still bounds memory/latency — so a single transient burst NEVER
        // flushes-to-IDR. It escalates to `.dropAndFlush` only on a GENUINE
        // sustained stall: the backlog stays at the hard ceiling across a streak
        // of assembled frames AND VT has produced no output for a stall window.
        // That `.dropAndFlush` routes DR_NEED_IDR so the VideoSink caller
        // (VideoRtpReceiver.depacketizerDidAssembleFrame) drives the depacketizer
        // into wait-for-IDR + one coalesced IDR request — the same self-heal
        // moonlight does when its bounded decodeUnitQueue overflows
        // (VideoDepacketizer.c:513-532). We deliberately do NOT also call
        // `backend?.requestIdrFrame()` here, so an overflow requests exactly one
        // IDR.
        switch reserveDecodeSlot() {
        case .reserved:
            break
        case .dropAndFlush:
            TelemetryCounters.shared.backlogOverflowTotal.increment()
            // This assembled frame is dropped before VT ever sees it — credit a
            // decoder-side discard so the drops-by-cause split counts it (it
            // never reaches recordDecodeComplete, the only counter the overlay's
            // decoder% used to read).
            statsCollector.recordDecoderDiscard()
            // INTENTIONAL NON-PRESENTATION ≠ LOSS. When presentation is suppressed
            // (window backgrounded / occluded / minimized), the present path has
            // stopped retiring frames, so the backlog overflows even though the
            // wire is healthy. Treating that like a reference-break and flushing
            // to IDR is exactly the "rfis/idrs and backflows when the window
            // isn't focused" bug. Drain the pacer FIFO to the freshest frame so
            // it can't grow unbounded, then return DR_OK (NOT DR_NEED_IDR): no
            // wire IDR, no depacketizer wait-for-IDR. The drop is still counted
            // above as a benign overflow, so telemetry stays measurable. The
            // single clean-repaint IDR for the whole episode is owned by the
            // refocus resync in `setPresentSuppressed(false)`.
            if presentSuppressed {
                framePacer?.dropToNewest(reason: "suppressed_backlog")
                return StreamProtocol.DR_OK
            }
            return StreamProtocol.DR_NEED_IDR
        }

        // If this is an IDR for H.264/HEVC, the parameter sets just changed
        // (or appeared for the first time). Tear down the existing session
        // and rebuild from the new parameter sets.
        let needsParamRebuild =
            (newSps != nil) || (newPps != nil) || (newVps != nil)
            || (decompressionSession == nil && isIDR)

        let pending = PendingDecode(
            pictureData: pictureData, newSps: newSps, newPps: newPps, newVps: newVps,
            needsParamRebuild: needsParamRebuild, isIDR: isIDR,
            rtpTimestamp: rtpTimestamp, totalLength: totalLength)

        decodeQueue.async { [self] in
            // Teardown gate: stop() may have flipped isStreaming off (and
            // handleCleanup may be queued behind us) between the receive thread
            // returning DR_OK and this block running. Skip VT work and DON'T
            // request an IDR against a backend that's tearing down — just
            // release the slot we reserved so the counter stays balanced.
            guard self.isStreaming else {
                self.releaseInFlightDecode()
                return
            }
            self.runDecodeOnQueue(pending)
        }

        return StreamProtocol.DR_OK
    }

    /// The VT half of the decode pipeline, run on the serial `decodeQueue`:
    /// param-set rebuild (when needed) → sample build → async VT submit. Split
    /// out of `decodeAssembledFrame` so the receive-thread half (backlog gate +
    /// dispatch) stays small. Each early-out releases the in-flight slot the
    /// caller reserved and routes the need-IDR signal asynchronously via
    /// `backend?.requestIdrFrame()` — the same thread-safe IDR route the VT
    /// output callback / renderer-failed path use. The success path's slot is
    /// released later by the VT output callback (`releaseInFlightDecode`), which
    /// fires exactly once per accepted submit.
    private nonisolated func runDecodeOnQueue(_ pending: PendingDecode) {
        let format = streamVideoFormat
        let pictureData = pending.pictureData

        if pending.needsParamRebuild,
           !rebuildParamSetsAndSession(
                newSps: pending.newSps, newPps: pending.newPps, newVps: pending.newVps,
                format: format, pictureData: pictureData) {
            // Param-rebuild / session-create failed: this frame never reaches
            // VT, so release its in-flight slot, credit a decoder-side discard
            // (it never reaches recordDecodeComplete), and request an IDR.
            releaseInFlightDecode()
            statsCollector.recordDecoderDiscard()
            log.error("Decode param/session setup failed — requesting IDR")
            OSSignposter.decode.emitEvent("IDRRequested", "trigger=param_rebuild_failed")
            backend?.requestIdrFrame()
            return
        }

        guard formatDescription != nil, let session = decompressionSession else {
            releaseInFlightDecode()
            statsCollector.recordDecoderDiscard()
            log.error("Decode session missing — requesting IDR")
            OSSignposter.decode.emitEvent("IDRRequested", "trigger=no_session")
            backend?.requestIdrFrame()
            return
        }

        // For H.264/HEVC, the Annex-B start codes need to be rewritten
        // to AVCC-style length prefixes before we hand to VideoToolbox.
        // For AV1, VT consumes the raw OBU stream directly per Apple's
        // AV1 sample-buffer docs.
        //
        // `rtpTimestamp` is the host's capture-clock presentation
        // timestamp in 90kHz units (Limelight.h: "To exactly recover
        // the RTP timestamp, use something like
        // CMTimeMake((int64_t)du->rtpTimestamp, 90000);"). We thread it
        // through the input sample's timing info; VT propagates it to
        // the output callback so the layer can make stale-frame drop
        // decisions in the host's clock instead of ours.
        let preparedSample: CMSampleBuffer?
        if (format & StreamProtocol.VIDEO_FORMAT_MASK_AV1) != 0 {
            preparedSample = makeSampleBuffer(
                rawData: pictureData, rtpTimestamp: pending.rtpTimestamp)
        } else {
            let avcc = convertAnnexBToAVCC(pictureData)
            preparedSample = makeSampleBuffer(rawData: avcc, rtpTimestamp: pending.rtpTimestamp)
        }

        guard let sample = preparedSample else {
            releaseInFlightDecode()
            statsCollector.recordDecoderDiscard()
            log.error("Sample-buffer build failed — requesting IDR")
            OSSignposter.decode.emitEvent("IDRRequested", "trigger=sample_build_failed")
            backend?.requestIdrFrame()
            return
        }

        submitSampleToVT(
            session: session, sample: sample,
            isIDR: pending.isIDR, totalLength: pending.totalLength,
            rtpTimestamp: pending.rtpTimestamp)
    }

    /// Apply newly-arrived parameter sets and (re)build the format description +
    /// decompression session for the negotiated codec. Runs on the decode queue.
    /// Returns true on success; false means the caller should request an IDR.
    private nonisolated func rebuildParamSetsAndSession(
        newSps: Data?, newPps: Data?, newVps: Data?, format: Int32, pictureData: Data
    ) -> Bool {
        if let sps = newSps { spsData = stripStartCode(sps) }
        if let pps = newPps { ppsData = stripStartCode(pps) }
        if let vps = newVps { vpsData = stripStartCode(vps) }

        let rebuilt: Bool
        if (format & StreamProtocol.VIDEO_FORMAT_MASK_H264) != 0 {
            rebuilt = rebuildH264FormatDescription()
        } else if (format & StreamProtocol.VIDEO_FORMAT_MASK_H265) != 0 {
            rebuilt = rebuildHEVCFormatDescription()
        } else if (format & StreamProtocol.VIDEO_FORMAT_MASK_AV1) != 0 {
            rebuilt = rebuildAV1FormatDescription(obuData: pictureData)
        } else {
            rebuilt = false
        }
        guard rebuilt else { return false }
        guard ensureDecompressionSession() else { return false }

        // STREAM DISCONTINUITY FLUSH. A parameter-set rebuild means the format
        // genuinely changed mid-stream (resolution / codec profile / colorspace),
        // not a loss recovery. Any samples still queued in the renderer were built
        // against the OLD format description; presenting them after the new format
        // engages can briefly show torn/old-geometry frames. Flush the renderer so
        // the layer starts clean on the new format. This rebuild is always
        // triggered by an IDR (the param sets ride the keyframe), so the very next
        // sample is a clean keyframe in the new format — the flush just guarantees
        // nothing stale precedes it. `sampleBufferRenderer.flush()` is documented
        // safe off the main thread, so calling it from the decode queue is fine.
        // Distinct from loss recovery: no IDR is requested here (the keyframe is
        // already in hand) and the depacketizer's reference state is untouched.
        if let renderer = displayLayer?.sampleBufferRenderer {
            renderer.flush()
            OSSignposter.render.emitEvent("DiscontinuityFlush", "trigger=param_rebuild")
        }
        // The pacer's jitter buffer also holds old-format samples; drop them to
        // the freshest so the new keyframe presents without draining stale
        // geometry first. No-op if pacing isn't up.
        framePacer?.clearQueue(reason: "discontinuity")
        return true
    }

    /// Submit one ready sample to VideoToolbox for ASYNCHRONOUS decode and book
    /// the per-frame `DecodeFrame` signpost interval. Runs on the decode queue.
    /// On an inline VT rejection the output callback will NOT fire, so this
    /// releases the in-flight slot, closes the abandoned interval, and requests
    /// an IDR. On success the slot is released later by the output callback.
    private nonisolated func submitSampleToVT(
        session: VTDecompressionSession, sample: CMSampleBuffer, isIDR: Bool, totalLength: Int32,
        rtpTimestamp: UInt32
    ) {
        // VT will hand the produced CVPixelBuffer to
        // `decompressionOutputCallback` (on a VT-internal thread).
        // _EnableAsynchronousDecompression lets VT pipeline frames
        // without head-of-line blocking.
        //
        // We deliberately do NOT pass _EnableTemporalProcessing here.
        // Temporal processing tells VT it may reorder frames into
        // display order — useful for streams with B-frames where the
        // decoder receives frames in coded order and the renderer
        // needs them in display order. Sunshine and GFE encode with
        // zero B-frames (low-latency encode, no reordering possible),
        // so temporal processing buys us nothing semantic and adds a
        // one-frame reordering buffer — measurable cost on real-time
        // game streaming (≈8ms at 120Hz, ≈4ms at 240Hz, end-to-end
        // photons-to-input). moonlight-qt's vt_avsamplelayer.mm also
        // omits this flag for the same reason. The realtime hint on
        // the session itself (set in ensureDecompressionSession via
        // kVTDecompressionPropertyKey_RealTime = true) is the right
        // knob; temporal processing was redundant cost on top.
        let flags: VTDecodeFrameFlags = [._EnableAsynchronousDecompression]
        var infoFlagsOut = VTDecodeInfoFlags()
        // Stamp submit-time into the stats collector so the matching output
        // callback can compute wall-clock decode latency. The collector's FIFO
        // keeps the start-time bookkeeping out of the C boundary and lets us
        // bail out gracefully if a frame is silently dropped between submit and
        // output. The `DecodeFrame` interval opens here; the matching close
        // fires from the VT output callback (or the abandon path below if VT
        // rejected the submit synchronously), with strict pairing through the
        // FIFO even though the callback fires on a different thread.
        let decodeSignpostID = OSSignposter.decode.makeSignpostID()
        let decodeIntervalState = OSSignposter.decode.beginInterval(
            "DecodeFrame",
            id: decodeSignpostID,
            "bytes=\(totalLength, privacy: .public) idr=\(isIDR, privacy: .public)")
        statsCollector.recordDecodeSubmit(intervalState: decodeIntervalState)
        // Latency telemetry stage t_submit (opt-in; nil = zero cost): stamp the
        // instant before we hand the frame to VideoToolbox, keyed by the same
        // rtpTimestamp that becomes the sample's PTS (the only identity VT
        // propagates to its output callback).
        FrameTimingTracker.shared?.recordSubmit(rtpTimestamp: rtpTimestamp)
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sample,
            flags: flags,
            frameRefcon: nil,
            infoFlagsOut: &infoFlagsOut)

        if decodeStatus != noErr {
            log.error("VTDecompressionSessionDecodeFrame failed: \(decodeStatus)")
            // -8969 (badDataErr) and -12909 (kVTVideoDecoderBadDataErr) mean the
            // bitstream is hosed; request a new IDR. The output callback will
            // NOT fire for a synchronously-rejected submit, so release the
            // in-flight slot here and pop our pending submit timestamp so the
            // FIFO stays aligned with the output callback's pops. Credit a
            // decoder-side discard too — VT rejected the frame inline, so it
            // never reaches recordDecodeComplete and would otherwise undercount.
            releaseInFlightDecode()
            statsCollector.recordDecoderDiscard()
            if let abandonedState = statsCollector.recordDecodeAbandoned() {
                OSSignposter.decode.endInterval(
                    "DecodeFrame",
                    abandonedState,
                    "outcome=abandoned status=\(decodeStatus, privacy: .public)")
            }
            OSSignposter.decode.emitEvent("IDRRequested", "trigger=vt_decode_rejected")
            backend?.requestIdrFrame()
        }
    }

    /// Outcome of a backlog reservation. Only two artifact-safe outcomes exist
    /// (see `decodeAssembledFrame`): reserve + decode, or drop + flush-to-IDR.
    /// There is deliberately no silent-drop case — a sink-side drop without a
    /// flush would orphan the reference chain the depacketizer believes is
    /// intact.
    enum DecodeSlotDecision {
        /// A slot was reserved; proceed to dispatch the decode. Balanced by a
        /// later `releaseInFlightDecode`.
        case reserved
        /// The backlog is genuinely stalled (at the hard ceiling, or full while
        /// VT has produced no output for the stall window). Drop this frame and
        /// flush-to-IDR. No slot was reserved.
        case dropAndFlush
    }

    /// Reserve one in-flight-decode slot for a frame about to be dispatched, or
    /// decide to drop-and-flush when the backlog is genuinely stalled.
    ///
    /// Burst absorption vs sustained-stall escalation:
    ///   * backlog < `maxInFlightDecodes` → reserve normally; reset the overflow
    ///     streak (the backlog drained back under the bound).
    ///   * `maxInFlightDecodes` ≤ backlog < `maxInFlightDecodeCeiling` AND VT is
    ///     ACTIVELY DRAINING (it produced output within the last
    ///     `decodeStallWindowSeconds`) → ABSORB: reserve anyway so the VPN burst
    ///     rides VT's pipeline instead of flushing-to-IDR. A transient burst is
    ///     never flushed, no matter how deep, as long as VT keeps retiring frames
    ///     — that's the whole point of the deep bound.
    ///   * VT has produced NO output for the stall window (genuine VT stall) OR
    ///     backlog ≥ `maxInFlightDecodeCeiling` (memory/latency ceiling even with
    ///     absorption) → `.dropAndFlush`.
    /// The VT-output clock (`secondsSinceLastDecodedFrame`) is the principled
    /// gate: it cleanly separates "transient burst VT is working through" from
    /// "VT genuinely stopped." `consecutiveBacklogOverflow` is tracked only for
    /// the diagnostic log (how long the burst has sat in the overflow zone), not
    /// as a flush trigger — flushing a deep-but-draining burst would defeat the
    /// bound bump and reintroduce the hitch.
    ///
    /// The matching decrement is `releaseInFlightDecode`, called when VT retires
    /// the frame (output callback) or on any abandon path. Lock-guarded because
    /// the count is read/written from both the receive thread (reserve) and the
    /// decode queue / VT output-callback thread (release).
    private nonisolated func reserveDecodeSlot() -> DecodeSlotDecision {
        inFlightDecodeLock.lock()
        let backlog = inFlightDecodes

        // Common case: under the nominal bound. Reserve and clear any streak.
        if backlog < maxInFlightDecodes {
            inFlightDecodes += 1
            consecutiveBacklogOverflow = 0
            inFlightDecodeLock.unlock()
            return .reserved
        }

        // At/over the nominal bound — a burst is building. Decide absorb vs
        // flush. `secondsSinceLastDecodedFrame()` is the VT-draining signal: it
        // advances on every VT output callback, so a small value means VT is
        // actively retiring frames (a transient burst it will drain), while a
        // value past the stall window means VT has genuinely stopped producing.
        let vtDraining =
            secondsSinceLastDecodedFrame() < VideoDecoder.decodeStallWindowSeconds
        let underCeiling = backlog < maxInFlightDecodeCeiling
        consecutiveBacklogOverflow += 1

        // Absorb the burst while VT is draining and we're under the hard ceiling.
        if vtDraining, underCeiling {
            inFlightDecodes += 1
            let depth = inFlightDecodes
            inFlightDecodeLock.unlock()
            OSSignposter.decode.emitEvent(
                "BacklogBurstAbsorbed", "depth=\(depth, privacy: .public)")
            return .reserved
        }

        // Genuine sustained stall (VT not draining, or hit the ceiling). Drop +
        // flush-to-IDR. `streak` is how many assembled frames sat in the overflow
        // zone before this escalation — large means a long burst, small means VT
        // hard-stopped immediately.
        let streak = consecutiveBacklogOverflow
        consecutiveBacklogOverflow = 0
        inFlightDecodeLock.unlock()
        log.warning(
            // swiftlint:disable:next line_length
            "Decode backlog stall (\(backlog) in flight, overflowStreak=\(streak), vtDraining=\(vtDraining)) — dropping frame, flushing to next IDR")
        OSSignposter.decode.emitEvent("IDRRequested", "trigger=decode_backlog_stall")
        return .dropAndFlush
    }

    /// Decrement the in-flight-decode backlog counter by one. Called exactly
    /// once per reserved frame: from the VT output callback when VT retires an
    /// accepted frame, or from an abandon path when the frame never reaches (or
    /// is rejected by) VT. Lock-guarded because the increment happens on the
    /// receive thread / decode queue while the success-path decrement happens on
    /// VT's internal output-callback thread.
    nonisolated func releaseInFlightDecode() {
        inFlightDecodeLock.lock()
        if inFlightDecodes > 0 { inFlightDecodes -= 1 }
        inFlightDecodeLock.unlock()
    }
}
