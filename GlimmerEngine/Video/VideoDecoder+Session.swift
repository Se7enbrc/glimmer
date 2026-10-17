// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// SPDX-FileCopyrightText: Moonlight Game Streaming Project contributors

//
//  VideoDecoder+Session.swift
//
//  VideoToolbox decompression-session management and the VT output callback that
//  enqueues decoded frames into the AVSampleBufferDisplayLayer. Split out of
//  VideoDecoder.swift to keep each unit focused; see that file for the decoder's
//  stored state.
//

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

        // Hand VT a retained self as the refcon: the callback runs on VT's own thread, possibly after the
        // last other reference is gone, and the deinit backstop doesn't drain async frames.
        // `releaseOutputCallbackRefcon()` balances it at every session-invalidation site.
        let refcon = Unmanaged.passRetained(self)
        let callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: VideoDecoder.decompressionOutputCallback,
            decompressionOutputRefCon: refcon.toOpaque())

        // HW decoder bring-up can't run until the first SPS/PPS, so this create
        // lands on the critical first-frame leg. Measure it: a signpost interval
        // for Instruments + a wall-clock ms gauge (glimmer_vt_session_create_ms).
        let createSignpostState = OSSignposter.decode.beginInterval("VTSessionCreate")
        let createStart = CFAbsoluteTimeGetCurrent()
        let (status, sessionOut) = makeSession(formatDesc, decoderSpec, destImageBufferAttrs, callback)
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

    typealias SessionFactory = @Sendable (
        CMVideoFormatDescription, _ decoderSpec: [String: Any], _ imageBufferAttributes: [String: Any],
        VTDecompressionOutputCallbackRecord
    ) -> (OSStatus, VTDecompressionSession?)

    nonisolated static let createSession: SessionFactory = { format, decoderSpec, imageBufferAttributes, callback in
        var callback = callback
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: decoderSpec as CFDictionary,
            imageBufferAttributes: imageBufferAttributes as CFDictionary,
            outputCallback: &callback,
            decompressionSessionOut: &session)
        return (status, session)
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
        VTDecompressionOutputCallback = { outputRefCon, frameRefCon, status, infoFlags, imageBuffer, presentationTimeStamp, _ in
            guard let outputRefCon else { return }
            let decoder = Unmanaged<VideoDecoder>.fromOpaque(outputRefCon)
                .takeUnretainedValue()

            // Retire one in-flight decode: VT delivers exactly one output
            // callback per accepted submit (success, drop, or error), so this
            // is the matching decrement for the increment `decodeAssembledFrame`
            // took before dispatching. Without it the bounded backlog counter
            // would never drain and we'd wedge at `maxInFlightDecodes`,
            // permanently dropping + requesting IDRs. Done first, before any
            // early return below, so every callback path retires its slot.
            let failed = status != noErr || imageBuffer == nil
            decoder.releaseInFlightDecode(vtFailed: failed)
            // A frame VT failed leaves every later P-frame referencing a hole:
            // resync to the next IDR (a no-op if an IDR has been fed since).
            if failed {
                decoder.noteVtDecodeFailure(epoch: UInt(bitPattern: frameRefCon), status: status)
            }

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
            // Preserve the PC's RTP clock for pacing and telemetry. At release, the
            // renderer displays immediately rather than scheduling against its Mac clock.
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
                decoder.scheduleFirstDecodedFrame()
            }
        }

    nonisolated func scheduleFirstDecodedFrame() {
        let generation = firstFrameLifecycleGeneration.load(ordering: .acquiring)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isStreaming,
                      self.firstFrameLifecycleGeneration.load(ordering: .acquiring) == generation else { return }
                self.onFirstDecodedFrame?()
            }
        }
    }

    /// Runs on VT's output thread for each decoded pixel buffer: tags it, wraps it in a CMSampleBuffer
    /// stamped with the PC's capture-clock `hostPTS` for pacing and telemetry, then hands it to
    /// the frame pacer, or presents it directly while pacing is down.
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

        let enqueueSignpostID = OSSignposter.render.makeSignpostID()
        let enqueueIntervalState = OSSignposter.render.beginInterval(
            "EnqueueFrame",
            id: enqueueSignpostID)
        defer {
            OSSignposter.render.endInterval("EnqueueFrame", enqueueIntervalState)
        }

        let controlHDR = hdrEnabled
        let color = resolveColorDescription(for: pixelBuffer, controlHDR: controlHDR)
        let probe = beginColorProbe(pixelBuffer, color: color, controlHDR: controlHDR)
        // Match the PC's pixel geometry rather than VT's display-aspect hint.
        CVBufferRemoveAttachment(pixelBuffer, kCVImageBufferPixelAspectRatioKey)
        attachColorAndHDRMetadata(to: pixelBuffer, color: color)
        finishColorProbe(probe, pixelBuffer: pixelBuffer)

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

        // Keep the PC's RTP PTS through VT for pacing and telemetry, including invalid PTS.
        // presentFrame marks the released image display-immediately; this clock is not
        // the renderer's default Mac host clock and must not schedule its display.
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

        guard let sb = sampleBuffer else { return }
        if let pacer = framePacer {
            pacer.submit(sb, hostPTS: hostPTS)
        } else {
            _ = presentFrame(sb)
        }
    }
}
