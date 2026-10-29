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
import Dispatch
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
        #if os(macOS)
        let createSignpostState = OSSignposter.decode.beginInterval("VTSessionCreate")
        let createStart = CFAbsoluteTimeGetCurrent()
        #endif
        let (status, sessionOut) = makeSession(formatDesc, decoderSpec, destImageBufferAttrs, callback)
        #if os(macOS)
        let createMs = (CFAbsoluteTimeGetCurrent() - createStart) * 1000.0
        OSSignposter.decode.endInterval(
            "VTSessionCreate", createSignpostState,
            "status=\(status, privacy: .public) ms=\(createMs, privacy: .public)")
        TelemetryCounters.shared.setVtSessionCreateMs(createMs)
        #endif

        guard status == noErr, let session = sessionOut else {
            // No session means no callback will ever consume the refcon -
            // balance the passRetained above so we don't leak self.
            refcon.release()
            log.error("VTDecompressionSessionCreate failed: \(status)")
            return false
        }
        self.outputCallbackRefcon = refcon

        configureDecompressionSession(session)

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
        retireInvalidatedDecodes()
    }

    // MARK: - VT output callback → AVSampleBufferDisplayLayer enqueue

    nonisolated static let decompressionOutputCallback:
        VTDecompressionOutputCallback = { outputRefCon, frameRefCon, status, infoFlags, imageBuffer, presentationTimeStamp, _ in
            #if os(macOS)
            let callbackEntry = DispatchTime.now().uptimeNanoseconds
            #endif
            guard let outputRefCon else { return }
            let decoder = Unmanaged<VideoDecoder>.fromOpaque(outputRefCon)
                .takeUnretainedValue()
            // Retire the accepted submit before any success/failure return so the bounded
            // decode backlog cannot retain a slot after this callback finishes.
            let failed = status != noErr || imageBuffer == nil
            let epoch = UInt(bitPattern: frameRefCon)
            guard decoder.releaseInFlightDecode(epoch: epoch, submitted: true, vtFailed: failed) else { return }
            #if os(macOS)
            let rtpTimestamp = VideoDecoder.rtpTimestamp(from: presentationTimeStamp)
            let tracker = FrameTimingTracker.shared
            let traceAttempt = tracker?.attemptForFrame(rtpTimestamp: rtpTimestamp)
            tracker?.recordOutput(rtpTimestamp: rtpTimestamp, uptimeNanos: callbackEntry,
                                  status: status, flags: infoFlags.rawValue,
                                  decoded: status == noErr && imageBuffer != nil && !infoFlags.contains(.frameDropped))
            defer {
                tracker?.recordCallbackFinished(rtpTimestamp: rtpTimestamp, entryNanos: callbackEntry,
                                                attemptID: traceAttempt)
            }
            #endif

            // A frame VT failed leaves every later P-frame referencing a hole:
            // resync to the next IDR (a no-op if an IDR has been fed since).
            if failed {
                decoder.noteVtDecodeFailure(epoch: epoch, status: status)
            }

            // Every live output completes its own submit, including drops and failures.
            let dropped = infoFlags.contains(.frameDropped) || status != noErr || imageBuffer == nil
            #if os(macOS)
            let intervalState = decoder.statsCollector.recordDecodeComplete(
                dropped: dropped, identity: StatsCollector.DecodeIdentity(epoch: epoch, rtpTimestamp: rtpTimestamp))

            // The callback identity closes its own span even when output arrives out of order.
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
            #else
            _ = decoder.statsCollector.recordDecodeComplete(dropped: dropped,
                identity: StatsCollector.DecodeIdentity(epoch: epoch,
                    rtpTimestamp: VideoDecoder.rtpTimestamp(from: presentationTimeStamp)))
            #endif

            guard !dropped, let imageBuffer else { return }
            // Stamp the decoded-frame timestamp so the StreamSession
            // watchdog gates on real decode output, not byte reception -
            // see `secondsSinceLastDecodedFrame()` for the rationale.
            decoder.statsCollector.recordDecodedFrame()
            // Preserve the PC's RTP clock for pacing and telemetry. At release, the
            // renderer displays immediately rather than scheduling against its Mac clock.
            decoder.enqueueDecodedFrame(
                imageBuffer, hostPTS: presentationTimeStamp, decodeEpoch: epoch)
            // First-frame fade-in trigger. Fires once per session AFTER
            // the frame has been pushed to the display layer, with a
            // ~50ms cushion so the OS compositor has had at least two
            // vsync cycles (8ms at 120Hz / 16ms at 60Hz) to actually
            // present the pixels before the window starts becoming
            // visible. Firing pre-enqueue meant the fade ramped 0 → ~10%
            // alpha against an empty layer (visible black), reading as
            // a thin letterbox flash before content swapped in.
            if decoder.claimFirstDecodedFrame() {
                // P2 CONNECT-HANDSHAKE: stamp the first decoded-frame instant (the
                // close of the "established → pixels" leg). See DecodeTelemetry.
                VideoDecoder.noteFirstDecodedFrameTelemetry()
                decoder.scheduleFirstDecodedFrame()
            }
        }

    /// VT may complete callbacks concurrently; only one may schedule the first-frame notification.
    nonisolated func claimFirstDecodedFrame() -> Bool {
        !firstDecodedFrameClaimed.exchange(true, ordering: .acquiringAndReleasing)
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
        _ pixelBuffer: CVPixelBuffer, hostPTS: CMTime, decodeEpoch: UInt = 0
    ) {
        // Discard frames once teardown has flipped isStreaming off. Without
        // this gate, VT decode callbacks already in flight when stop() runs
        // can push one last frame at a layer we're about to release.
        guard isStreaming else { return }
        // Gate on the layer existing before the per-frame wrap work; the actual
        // enqueue happens later in `presentFrame`, which re-reads displayLayer.
        guard displayLayer != nil else { return }

        #if os(macOS)
        let enqueueSignpostID = OSSignposter.render.makeSignpostID()
        let enqueueIntervalState = OSSignposter.render.beginInterval(
            "EnqueueFrame",
            id: enqueueSignpostID)
        defer {
            OSSignposter.render.endInterval("EnqueueFrame", enqueueIntervalState)
        }
        #endif

        let controlHDR = hdrEnabled
        let color = resolveColorDescription(for: pixelBuffer, controlHDR: controlHDR)
        #if os(macOS)
        let probe = beginColorProbe(pixelBuffer, color: color, controlHDR: controlHDR)
        #endif
        // Match the PC's pixel geometry rather than VT's display-aspect hint.
        CVBufferRemoveAttachment(pixelBuffer, kCVImageBufferPixelAspectRatioKey)
        attachColorAndHDRMetadata(to: pixelBuffer, color: color)
        #if os(macOS)
        finishColorProbe(probe, pixelBuffer: pixelBuffer)
        #endif

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

        // Keep the PC's RTP clock for pacing and telemetry, and the decode epoch for admission.
        // The renderer displays immediately; these values never schedule against Mac time.
        var presentationTime = hostPTS
        presentationTime.epoch = Int64(bitPattern: UInt64(decodeEpoch))
        var timingInfo = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: presentationTime,
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
        let route = presentationRoute()
        if let pacer = route.pacer {
            #if os(macOS)
            FrameTimingTracker.shared?.recordPacerSubmitted(rtpTimestamp: Self.rtpTimestamp(from: hostPTS))
            #endif
            pacer.submit(sb, hostPTS: hostPTS)
        } else {
            _ = presentFrame(sb, modeGeneration: route.generation)
        }
    }
}
