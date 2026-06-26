//
//  VideoDecoder+Session.swift
//
//  VideoToolbox decompression-session management and the VT output callback that
//  enqueues decoded frames into the AVSampleBufferDisplayLayer. Split out of
//  VideoDecoder.swift to keep each unit focused; see that file for the decoder's
//  stored state.
//

import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import os

extension VideoDecoder {

    // MARK: - Decompression session

    nonisolated func ensureDecompressionSession(
        cause: SessionCreateCause = .firstCreate
    ) -> Bool {
        if decompressionSession != nil { return true }
        guard let formatDesc = formatDescription else { return false }

        let isTenBit = (streamVideoFormat & StreamProtocol.VIDEO_FORMAT_MASK_10BIT) != 0
        // 4:4:4 streams (HEVC RExt / AV1 High 4:4:4) decode into the full-chroma
        // bi-planar output formats; asking VT for a 4:2:0 output on a 4:4:4
        // bitstream throws away the very chroma resolution we negotiated for.
        // The 4:4:4 formats only get here when a YUV444 VIDEO_FORMAT negotiated
        // (host offered + we probed support), so older Macs never reach them.
        let is444 = (streamVideoFormat & StreamProtocol.VIDEO_FORMAT_MASK_YUV444) != 0
        let outputPixelFormat: OSType
        switch (is444, isTenBit) {
        case (true, true):   outputPixelFormat = kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange
        case (true, false):  outputPixelFormat = kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange
        case (false, true):  outputPixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        case (false, false): outputPixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        }

        let destImageBufferAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: outputPixelFormat,
            // IOSurface backing is required for direct AVSampleBufferDisplayLayer
            // ingestion without a copy - the layer's compositor reads the
            // IOSurface directly. moonlight-qt's vt_avsamplelayer.mm relies on
            // the same path (FFmpeg's VT hwaccel already opts in via
            // av_hwdevice_ctx_create).
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]

        // Force HW; software AV1/HEVC decoding at 4K60 would be a disaster.
        let decoderSpec: [String: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder as String: true,
            kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder as String: true
        ]

        // Hand the VT output callback a *retained* reference to self via the
        // refcon. The callback fires asynchronously on the decode queue and
        // resolves the decoder with `takeUnretainedValue()`. A passUnretained
        // refcon would let a decode-in-flight callback dereference a
        // deallocating VideoDecoder if the last strong ref dropped between
        // submit and output - the `isolated deinit` backstop invalidates the
        // session WITHOUT draining async frames, so that race is reachable.
        // The +1 retain keeps the decoder alive for as long as the session
        // that holds the refcon lives; it is balanced by
        // `releaseOutputCallbackRefcon()` at every session-invalidation site.
        let refcon = Unmanaged.passRetained(self)
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: VideoDecoder.decompressionOutputCallback,
            decompressionOutputRefCon: refcon.toOpaque())

        // HW decoder bring-up can't run until the first SPS/PPS, so this create
        // lands on the critical first-frame leg. Measure it: a signpost interval
        // for Instruments + a wall-clock ms gauge (glimmer_vt_session_create_ms).
        let createSignpostState = OSSignposter.decode.beginInterval("VTSessionCreate")
        let createStart = CFAbsoluteTimeGetCurrent()
        var sessionOut: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDesc,
            decoderSpecification: decoderSpec as CFDictionary,
            imageBufferAttributes: destImageBufferAttrs as CFDictionary,
            outputCallback: &callback,
            decompressionSessionOut: &sessionOut)
        let createMs = (CFAbsoluteTimeGetCurrent() - createStart) * 1000.0
        OSSignposter.decode.endInterval(
            "VTSessionCreate", createSignpostState,
            "status=\(status, privacy: .public) ms=\(createMs, privacy: .public)")
        TelemetryCounters.shared.setVtSessionCreateMs(createMs)

        guard status == noErr, let session = sessionOut else {
            // No session means no callback will ever consume the refcon -
            // balance the passRetained above so we don't leak self.
            refcon.release()
            log.error("VTDecompressionSessionCreate failed: \(status)")
            return false
        }
        self.outputCallbackRefcon = refcon

        // Real-time hint - lets VT prefer latency over throughput. The
        // capture path on the host already paces frames; we want them out
        // ASAP. moonlight-qt sets the equivalent via ffmpeg's VT hwaccel
        // path; we set it directly here.
        VTSessionSetProperty(
            session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        // Disable any power-savings deferrals - every millisecond of decode
        // latency adds end-to-end input-to-photon latency, which is what we
        // sell. Available on macOS 10.10+; ignore failures on older OSes.
        VTSessionSetProperty(
            session,
            key: kVTDecompressionPropertyKey_MaximizePowerEfficiency,
            value: kCFBooleanFalse)
        // Don't let VT reorder; Sunshine/GFE streams have no B-frames and
        // we want strictly-monotonic display order.
        VTSessionSetProperty(
            session, key: kVTDecompressionPropertyKey_ThreadCount, value: 1 as CFNumber)

        self.decompressionSession = session
        // Telemetry (opt-in): a fresh VT session was built - bump the recreate
        // counter (total + by-cause) + publish the live DECODE state (gate-on).
        noteSessionCreatedTelemetry(outputPixelFormat: outputPixelFormat, cause: cause)
        return true
    }

    /// Release the +1 self-retain the VT output callback holds via its refcon
    /// (created in `ensureDecompressionSession`). Idempotent - nil'ing the
    /// stored `Unmanaged` guards against a double-release if two teardown
    /// paths race. Call immediately after `VTDecompressionSessionInvalidate`
    /// at every invalidation site.
    nonisolated func releaseOutputCallbackRefcon() {
        outputCallbackRefcon?.release()
        outputCallbackRefcon = nil
    }

    nonisolated func tearDownDecompressionSession() {
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
        }
        decompressionSession = nil
        releaseOutputCallbackRefcon()
    }

    // MARK: - VT output callback → AVSampleBufferDisplayLayer enqueue

    nonisolated static let decompressionOutputCallback:
        VTDecompressionOutputCallback = { decompressionOutputRefCon, _, status, infoFlags, imageBuffer, presentationTimeStamp, _ in
            guard let decompressionOutputRefCon else { return }
            let decoder = Unmanaged<VideoDecoder>.fromOpaque(decompressionOutputRefCon)
                .takeUnretainedValue()

            // Retire one in-flight decode: VT delivers exactly one output
            // callback per accepted submit (success, drop, or error), so this
            // is the matching decrement for the increment `decodeAssembledFrame`
            // took before dispatching. Without it the bounded backlog counter
            // would never drain and we'd wedge at `maxInFlightDecodes`,
            // permanently dropping + requesting IDRs. Done first, before any
            // early return below, so every callback path retires its slot.
            decoder.releaseInFlightDecode()

            // Stats: every output callback completes one submit, even when
            // VT reports the frame as dropped (status != noErr or the
            // FrameDropped info bit). Pop the pending submit timestamp first
            // so the FIFO stays aligned with submits.
            let dropped = infoFlags.contains(.frameDropped) || status != noErr || imageBuffer == nil
            let intervalState = decoder.statsCollector.recordDecodeComplete(dropped: dropped)

            // Close the `DecodeFrame` interval against the same state the
            // submit side opened with. The FIFO pairing via the collector
            // is what lets Instruments draw a clean per-frame interval
            // even though submit and complete straddle a queue hop.
            if let intervalState {
                let outcome: StaticString = dropped ? "dropped" : "ok"
                OSSignposter.decode.endInterval(
                    "DecodeFrame",
                    intervalState,
                    "outcome=\(outcome, privacy: .public) status=\(status, privacy: .public)")
            }

            // Emit a `FrameDropped` event for the kVTDecodeInfo_FrameDropped
            // bit (matches the red-triangle convention in the Instruments
            // OSSignpost timeline). The event is per-frame and intentionally
            // separate from the interval close so a profile run can filter
            // for drops without scanning interval-end payloads.
            if dropped {
                let reason: StaticString
                if status != noErr {
                    reason = "vt_status_error"
                } else if infoFlags.contains(.frameDropped) {
                    reason = "vt_info_dropped"
                } else {
                    reason = "no_image_buffer"
                }
                OSSignposter.decode.emitEvent(
                    "FrameDropped",
                    "reason=\(reason, privacy: .public) status=\(status, privacy: .public)")
                // P2 CORRUPTION/ARTIFACT heuristic (signal: quality) - counted in
                // the DecodeTelemetry helper for a VT decode-STATUS error (the cheap
                // white/purple-flash-class tell; see noteCorruptionIfDecodeError).
                VideoDecoder.noteCorruptionIfDecodeError(status: status)
            }

            guard status == noErr, let imageBuffer else { return }
            // Stamp the decoded-frame timestamp so the StreamSession
            // watchdog gates on real decode output, not byte reception -
            // see `secondsSinceLastDecodedFrame()` for the rationale.
            decoder.statsCollector.recordDecodedFrame()
            // Latency telemetry stage t_output (opt-in; nil = zero cost): VT just
            // produced the frame. Recover the rtpTimestamp key from the PTS VT
            // propagated (built as CMTimeMake(rtpTimestamp, 90000)).
            if let tracker = FrameTimingTracker.shared {
                tracker.recordOutput(rtpTimestamp: VideoDecoder.rtpTimestamp(from: presentationTimeStamp))
            }
            // Propagate the host-clock PTS (recovered from the input
            // sample's rtpTimestamp via VT) into the enqueue path so the
            // AVSampleBufferDisplayLayer can drop stale frames cleanly.
            decoder.enqueueDecodedFrame(
                imageBuffer, hostPTS: presentationTimeStamp)
            // First-frame fade-in trigger. Fires once per session AFTER
            // the frame has been pushed to the display layer, with a
            // ~50ms cushion so the OS compositor has had at least two
            // vsync cycles (8ms at 120Hz / 16ms at 60Hz) to actually
            // present the pixels before the window starts becoming
            // visible. Firing pre-enqueue meant the fade ramped 0 → ~10%
            // alpha against an empty layer (visible black), reading as
            // a thin letterbox flash before content swapped in.
            if !decoder.didFireFirstDecodedFrame {
                decoder.didFireFirstDecodedFrame = true
                // P2 CONNECT-HANDSHAKE: stamp the first decoded-frame instant (the
                // close of the "established → pixels" leg). See DecodeTelemetry.
                VideoDecoder.noteFirstDecodedFrameTelemetry()
                if let cb = decoder.onFirstDecodedFrame {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        MainActor.assumeIsolated { cb() }
                    }
                }
            }
        }

    /// Called on the decode queue when VT produces a CVPixelBuffer.
    /// Wraps the pixel buffer in a CMSampleBuffer and SUBMITS it to the frame
    /// pacer (`FramePacer`), which holds it in a bounded hostPTS-ordered jitter
    /// buffer and releases it to the AVSampleBufferDisplayLayer's renderer on
    /// the display's true vsync via a CADisplayLink - so network-arrival jitter
    /// no longer maps 1:1 onto screen time. (We used to call renderer.enqueue
    /// inline here, the instant VT decoded, which is the micro-stutter this
    /// pass removes.) There is no Metal render pass on our side; the OS still
    /// owns the final v-sync present once the pacer hands a frame off.
    ///
    /// `hostPTS` is the host's capture-clock presentation timestamp,
    /// recovered from `du.rtpTimestamp` (90kHz units) via VT's PTS
    /// propagation through the input sample's timing info. We stamp the
    /// output CMSampleBuffer's PTS with it so the layer can make stale-
    /// frame drop decisions in the host's clock - under stutter (renderer
    /// blocked, OS-side compositor falling behind, host bitrate spike) the
    /// layer sees PTSes from before the stall and drops them cleanly when
    /// it resumes, rather than catching up frame-by-frame and never
    /// recovering. Previously this used `mach_absolute_time()` on our own
    /// clock, which left every PTS monotonically advancing regardless of
    /// host-side timing and gave the layer no signal to detect "this frame
    /// is stale, skip it."
    nonisolated func enqueueDecodedFrame(
        _ pixelBuffer: CVPixelBuffer, hostPTS: CMTime
    ) {
        // Discard frames once teardown has flipped isStreaming off. Without
        // this gate, VT decode callbacks already in flight when stop() runs
        // can push one last frame at a layer we're about to release.
        guard isStreaming else { return }
        // Gate on the layer existing before the per-frame wrap work; the actual
        // enqueue happens later in `presentFrame`, which re-reads displayLayer.
        guard displayLayer != nil else { return }

        // `EnqueueFrame` interval: VT output callback → sample buffer built
        // and handed to the frame pacer's submit (the actual renderer.enqueue
        // now happens later, on the pacer's serial queue at the due vsync -
        // see `presentFrame`). Stays entirely on this thread so a per-call
        // interval state (no FIFO needed). Target is sub-1ms p99 at 4K60.
        let enqueueSignpostID = OSSignposter.render.makeSignpostID()
        let enqueueIntervalState = OSSignposter.render.beginInterval(
            "EnqueueFrame",
            id: enqueueSignpostID)
        defer {
            OSSignposter.render.endInterval("EnqueueFrame", enqueueIntervalState)
        }

        // Strip VT-attached pixel-aspect-ratio attachment - verbatim from
        // moonlight-qt's vt_avsamplelayer.mm:220:
        //
        //   // The VideoToolbox decoder attaches pixel aspect ratio information
        //   // to the CVPixelBuffer which will rescale the video stream in
        //   // accordance with the host display resolution to preserve the
        //   // original aspect ratio of the host desktop. This behavior
        //   // currently differs from the behavior of all other Moonlight Qt
        //   // renderers, so we will strip these attachments for consistent
        //   // behavior.
        //   CVBufferRemoveAttachment(pixBuf, kCVImageBufferPixelAspectRatioKey);
        CVBufferRemoveAttachment(pixelBuffer, kCVImageBufferPixelAspectRatioKey)

        // Attach the bitstream-derived colorspace, the per-attribute color
        // triple override, and any host HDR metadata to the pixel buffer (a
        // verbatim port of vt_avsamplelayer.mm:222-262). Returns the derived
        // colorspace key the first-frame probe below reports against.
        let derivedKey = attachColorAndHDRMetadata(to: pixelBuffer)

        // First-frame diagnostic probe AFTER our attaches so the log shows
        // what the layer will actually see at composite time (pre-attach
        // state is captured below for comparison).
        if !didLogFirstPixelBufferProbe {
            didLogFirstPixelBufferProbe = true
            probeAndLogPixelBufferAttachments(pixelBuffer, derivedKey: derivedKey)
        }

        // Rebuild the CMVideoFormatDescription to match the (possibly newly-
        // attached) pixel buffer. CMVideoFormatDescriptionCreateForImageBuffer
        // reads the pixel buffer's attachments and propagates them onto the
        // produced format description's extensions dict, including the HDR10
        // MDCV/CLL we just attached. moonlight-qt rebuilds this whenever
        // CMVideoFormatDescriptionMatchesImageBuffer returns false; we cache
        // off `cachedHDRFormatDescription` and invalidate it whenever the
        // SPS/PPS/VPS changes or the HDR metadata changes.
        var fmtDesc: CMVideoFormatDescription?
        if let cached = cachedHDRFormatDescription,
           CMVideoFormatDescriptionMatchesImageBuffer(cached, imageBuffer: pixelBuffer) {
            fmtDesc = cached
        } else {
            var newFmt: CMVideoFormatDescription?
            let st = CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &newFmt)
            if st != noErr || newFmt == nil {
                log.error("CMVideoFormatDescriptionCreateForImageBuffer failed: \(st)")
                return
            }
            cachedHDRFormatDescription = newFmt
            fmtDesc = newFmt
        }

        guard let formatDescription = fmtDesc else { return }

        // Build the CMSampleBuffer. PTS comes from the host's capture
        // clock (rtpTimestamp in 90kHz units), recovered by VT through the
        // input sample's timing info and surfaced as
        // `presentationTimeStamp` in the output callback. When PTS is
        // invalid (older Sunshine builds, defensive path), fall back to
        // `.invalid` - the layer will still render but its stale-frame
        // drop logic loses precision. We deliberately do NOT synthesize
        // a local mach_absolute_time PTS here; that's the bug this fix
        // closes. moonlight-qt's vt_avsamplelayer.mm follows the same
        // host-PTS path.
        var timingInfo = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: hostPTS,
            decodeTimeStamp: .invalid)

        var sampleBuffer: CMSampleBuffer?
        let st = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sampleBuffer)
        if st != noErr || sampleBuffer == nil {
            log.error("CMSampleBufferCreateReadyWithImageBuffer failed: \(st)")
            return
        }

        // ---- Hand the ready sample buffer to the FRAME PACER instead of
        // enqueueing it straight onto the renderer.
        //
        // This is the heart of the buttery-smooth pass. Previously we called
        // renderer.enqueue() right here - the instant VT finished decoding -
        // so network-arrival jitter on the host capture clock mapped 1:1 onto
        // screen time and motion juddered even on a perfectly-paced panel. The
        // pacer interposes a bounded, hostPTS-ordered jitter buffer and a
        // CADisplayLink-gated release: each frame waits in the buffer until its
        // due vsync, then presents on the display's true cadence (60 / 120
        // ProMotion-variable / 240 Hz, read live from the link, never
        // hardcoded). The renderer-status + backpressure policy that used to
        // live inline now runs inside `presentFrame(_:)`, which the pacer
        // invokes via its `willPresent` hook on its dedicated serial queue at
        // the moment of release. See FramePacer.swift for the model (a port of
        // moonlight-qt's pacer.cpp two-queue design).
        //
        // If the pacer isn't up yet (very early frame before the stream view
        // has a window+screen, or a defensive path) fall back to presenting
        // directly so we never black-screen waiting for the link.
        guard let sb = sampleBuffer else { return }
        if let pacer = framePacer {
            pacer.submit(sb, hostPTS: hostPTS)
        } else {
            _ = presentFrame(sb)
        }
    }

    /// Attach the bitstream-derived CGColorSpace, the per-attribute color-triple
    /// override, and any cached host HDR metadata onto `pixelBuffer`. A verbatim
    /// port of moonlight-qt's vt_avsamplelayer.mm:222-262, extracted out of
    /// `enqueueDecodedFrame` so the per-frame path stays focused. Returns the
    /// derived colorspace key so the caller's first-frame probe can report it.
    private nonisolated func attachColorAndHDRMetadata(to pixelBuffer: CVPixelBuffer) -> String {
        // ---- Colorspace attach (verbatim port of vt_avsamplelayer.mm:222-254)
        //
        // Read the bitstream-declared color metadata off the pixel buffer.
        // VT propagates the VUI / OBU `colour_description_present_flag` data
        // into kCVImageBufferColorPrimaries / TransferFunction / YCbCrMatrix
        // attachments on the produced CVPixelBuffer. We derive the effective
        // colorspace by mapping (primaries, transfer) → CGColorSpace, in the
        // same order moonlight-qt does: BT.2020 + SMPTE2084 → kCGColorSpace-
        // ITUR_2100_PQ; BT.2020 (no PQ) → kCGColorSpaceITUR_2020; BT.709 →
        // kCGColorSpaceITUR_709; everything else → sRGB.
        //
        // Critically - and this is where Glimmer used to diverge - we attach
        // this colorspace on EVERY FRAME unconditionally. VT often leaves an
        // sRGB-equivalent default attachment on the buffer when the bitstream
        // didn't tag its color metadata, which the layer then renders as if
        // sRGB even when PQ codes are sitting in the YUV planes - that's the
        // washed-out overbright HDR symptom. moonlight-qt's loop always calls
        // `CVBufferSetAttachment(pixBuf, kCVImageBufferCGColorSpaceKey, ...)`
        // after computing the colorspace; we match that contract here.
        let derivedKey = derivedColorSpaceKey(for: pixelBuffer)
        if derivedKey != lastColorSpaceKey {
            lastColorSpace = makeCGColorSpace(forKey: derivedKey)
            lastColorSpaceKey = derivedKey
            log.info("Bitstream colorspace changed: \(derivedKey, privacy: .public)")
            // Telemetry (opt-in): refresh the DECODE colorspace label (gate in helper).
            noteColorSpaceChangeTelemetry(derivedKey)
        }
        if let cs = lastColorSpace {
            CVBufferSetAttachment(
                pixelBuffer,
                kCVImageBufferCGColorSpaceKey,
                cs,
                .shouldPropagate)
        }

        // ALSO override the per-attribute color triple (primaries / transfer
        // function / YCbCr matrix). VT populates these from the bitstream's
        // VUI / OBU, but Sunshine ships PQ Main10 with the VUI tagged as
        // BT.709 on a number of GPU/driver combos - so VT writes 709 onto
        // an actually-PQ frame. macOS's HDR-engagement heuristic cross-
        // checks the CGColorSpace attachment against these triple attrs
        // and, if they conflict, refuses to engage display HDR (the symptom:
        // a single-frame flash of correct HDR brightness when the layer
        // first comes up, then macOS disengages and the panel falls back
        // to SDR with PQ codes tone-mapped down → dark and grey).
        // The fix is to override these to match whatever CGColorSpace we
        // attached. When SDR, we leave VT's tags alone.
        if derivedKey == "itur_2100_PQ" {
            CVBufferSetAttachment(pixelBuffer,
                kCVImageBufferColorPrimariesKey,
                kCVImageBufferColorPrimaries_ITU_R_2020,
                .shouldPropagate)
            CVBufferSetAttachment(pixelBuffer,
                kCVImageBufferTransferFunctionKey,
                kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
                .shouldPropagate)
            CVBufferSetAttachment(pixelBuffer,
                kCVImageBufferYCbCrMatrixKey,
                kCVImageBufferYCbCrMatrix_ITU_R_2020,
                .shouldPropagate)
        } else if derivedKey == "itur_2020" {
            CVBufferSetAttachment(pixelBuffer,
                kCVImageBufferColorPrimariesKey,
                kCVImageBufferColorPrimaries_ITU_R_2020,
                .shouldPropagate)
            CVBufferSetAttachment(pixelBuffer,
                kCVImageBufferYCbCrMatrixKey,
                kCVImageBufferYCbCrMatrix_ITU_R_2020,
                .shouldPropagate)
        }

        // Attach HDR metadata to the pixel buffer if the host has provided
        // it. moonlight-qt's vt_avsamplelayer.mm:257-262 does this via
        // CVBufferSetAttachment with kCVImageBufferMasteringDisplayColorVolumeKey
        // / kCVImageBufferContentLightLevelInfoKey on each frame. The
        // attachments are the same GBR-ordered big-endian byte blobs we
        // build in refreshHDRMetadataFromHost.
        if let mdcv = cachedMDCV {
            CVBufferSetAttachment(
                pixelBuffer,
                kCVImageBufferMasteringDisplayColorVolumeKey,
                mdcv as CFData,
                .shouldPropagate)
        }
        if let cll = cachedContentLightLevel {
            CVBufferSetAttachment(
                pixelBuffer,
                kCVImageBufferContentLightLevelInfoKey,
                cll as CFData,
                .shouldPropagate)
        }

        return derivedKey
    }

    /// Present one paced frame onto the AVSampleBufferDisplayLayer's renderer.
    /// Invoked by `FramePacer` via its `willPresent` hook on the pacer's
    /// dedicated serial queue (NOT the main actor) at the moment a frame is due
    /// for its vsync - or inline from `enqueueDecodedFrame` on the fallback
    /// path when the pacer isn't running. Returns true if the frame was handed
    /// to the renderer, false if it was dropped (renderer failed / not ready).
    ///
    /// This owns the renderer-status + backpressure policy that used to live
    /// inline in the VT callback:
    ///   * renderer.status == .failed → flush + request an IDR (unchanged).
    ///   * renderer not ready for more media → drop + count (no IDR here; a
    ///     presentation-timing drop of an already-decoded frame never requests a
    ///     keyframe - the reference chain is intact).
    @discardableResult
    nonisolated func presentFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        // Re-check the teardown gate: the pacer's serial queue can race a
        // MainActor teardown that nil'd the layer. Snapshot the layer into a
        // local so it can't be released mid-enqueue.
        guard isStreaming, let layer = displayLayer else { return false }

        // ---- Renderer via the macOS 15+ AVSampleBufferVideoRenderer path.
        //
        // On macOS 15+, calling `enqueueSampleBuffer:` (and the matching
        // flush/status/error) directly on the AVSampleBufferDisplayLayer
        // is deprecated. The replacement is `layer.sampleBufferRenderer`
        // (AVSampleBufferVideoRenderer), which is explicitly safe to drive
        // from a background thread - exactly the pacer's serial queue here.
        //
        // If the renderer's status latched to `.failed` (bad sample, an HDR
        // mid-stream toggle, or other decoder glitch), it silently stops
        // rendering further enqueued samples until we call `flush()`.
        // moonlight-qt handles the equivalent on older macOS by pushing
        // SDL_RENDER_DEVICE_RESET and recreating the decoder. We do it
        // cheaper: flush + request an IDR via the backend, and let VT pick
        // up where it left off.
        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed {
            log.warning(
                "AVSampleBufferDisplayLayer renderer FAILED; self-healing (error=\(String(describing: renderer.error)))")
            // Surface the "I lost a frame to the OS" moment as a discrete
            // event so a profile run can spot the recovery amongst the
            // per-frame intervals.
            OSSignposter.render.emitEvent(
                "RendererFailed",
                "error=\(String(describing: renderer.error), privacy: .public)")
            // Route to the MODE-AGNOSTIC self-heal: flush, and if the renderer
            // has HARD-failed (a bare flush won't clear it - the 4K240
            // HDR wedge), REBUILD the layer so the present path can't latch
            // failed forever (the old behaviour: flush-noop → IDR → return false
            // every frame, decode healthy, screen frozen, no escalation). The
            // recovery hops to the main actor to touch AppKit; we drop THIS
            // frame and the next keyframe lands on the recovered layer.
            recoverPresentPathFromRenderQueue(reason: "renderer_failed")
            return false
        }

        // ---- Renderer backpressure (Apple docs explicitly recommend dropping
        // for live content). When AVSampleBufferVideoRenderer's internal queue
        // fills, `isReadyForMoreMediaData` flips to false. The pacer already
        // bounds our own wall-clock latency upstream, so a not-ready renderer
        // here is the OS-side queue momentarily full - we drop this frame and
        // count it, but DON'T request an IDR off it: a single late vsync can
        // flip the flag for one frame, and an IDR on transient jitter just
        // compounds lag. A presentation-timing drop of an already-decoded frame
        // never requests a keyframe - the reference chain is intact.
        if !renderer.isReadyForMoreMediaData {
            consecutiveBackpressureDrops += 1
            statsCollector.recordRendererBackpressureDrop()
            OSSignposter.render.emitEvent(
                "BackpressureDrop",
                "streak=\(self.consecutiveBackpressureDrops, privacy: .public)")
            return false
        }

        // Healthy frame - reset the backpressure streak and present.
        consecutiveBackpressureDrops = 0
        renderer.enqueue(sampleBuffer)

        // Latency telemetry stage t_present (opt-in; nil = zero cost): the frame
        // just reached the renderer. Recover the rtpTimestamp key from the sample
        // buffer's PTS, look up the in-flight entry, compute the five deltas, feed
        // the histograms + per-frame trace, and evict. This is the only stage that
        // mutates the histograms / appends a trace line, all off the proven path.
        if let tracker = FrameTimingTracker.shared {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let rtpTimestamp = VideoDecoder.rtpTimestamp(from: pts)
            tracker.recordPresent(rtpTimestamp: rtpTimestamp)
            // AV-skew VIDEO half (`av_skew_ms`): the host-timeline RTP of the
            // frame that just reached the renderer - the one-word store the
            // deferred cross-stream derivation needed. Inside the tracker
            // nil-check so telemetry-off sessions stay zero-cost.
            AudioVideoSkewStore.shared.noteVideoPresented(rtp: rtpTimestamp)
        }

        // Stats: one renderer enqueue equals one frame handed to the OS for
        // v-sync presentation. The OS may still drop it at composite time if
        // it falls behind, but that's outside our visibility - moonlight-qt's
        // "rendering FPS" row is defined the same way.
        statsCollector.recordRendererEnqueue()
        return true
    }

    // A presentation-late / drop-to-newest / sustained-lag drop in the
    // FramePacer discards an ALREADY-DECODED CMSampleBuffer from the present
    // queue - the VideoToolbox decoder already decoded it, so the reference
    // chain is INTACT and NO IDR is needed. Requesting a keyframe for a
    // presentation-timing drop is a category error: it can't fix pacing, and at
    // 4K240 the bitrate-capped IDR arrives soft/blocky then refines = a
    // visible blur/refocus. The old `notePacerSustainedLag` IDR-after-N
    // trigger (and the pacer's `onSustainedLag` signal that fed it) is therefore
    // GONE - the pacer keeps trimming-to-newest and keeps counting
    // presentation-late drops (that telemetry is correct + load-bearing), but
    // never escalates a pacing trim to a keyframe. IDR/RFI is now reserved for
    // GENUINE decode/reference breaks only: real packet loss (the depacketizer
    // RFI state machine) or a VT decode error.
}
