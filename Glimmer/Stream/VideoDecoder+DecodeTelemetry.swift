//
//  VideoDecoder+DecodeTelemetry.swift
//
//  P1 DECODE-side telemetry capture for the opt-in exporter, split out of
//  VideoDecoder+Session.swift so that file stays under the length budget and
//  focused on the VT session lifecycle. These are CAPTURE-ONLY helpers - they add
//  no behavior to the decode path; they only publish what the session already
//  knows (HW-decode confirmation, pixel format, bit depth, colorspace) to the
//  always-live `TelemetryCounters` for the exporter to read at 1Hz.
//
//  GATING + HOT-PATH SAFETY (load-bearing - see TelemetryExporter.swift): the
//  recreate counter is an always-live integer add at the already-rare VT-create
//  site; the state PUBLISH is gated on `FrameTimingTracker.shared != nil` (the
//  gate-on sentinel) so the OFF path pays only that one optional load. Both call
//  sites are off the per-frame hot path (session-create + colorspace-change are
//  rare events), and nothing here touches the proven decode/pace locks.
//

import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

extension VideoDecoder {

    /// Recover the host's rtpTimestamp (90kHz capture-clock PTS) from a CMTime
    /// that was built as `CMTimeMake(rtpTimestamp, 90000)` (see makeSampleBuffer).
    /// VT propagates this PTS verbatim to the output callback and the pacer carries
    /// it on the CMSampleBuffer, so it is the frame-identity key the latency
    /// tracker uses across the VideoToolbox boundary. Returns 0 for an invalid PTS
    /// (older Sunshine / defensive path) - which the tracker treats as "untracked".
    /// Lives here because the latency telemetry rig is its only purpose.
    nonisolated static func rtpTimestamp(from pts: CMTime) -> UInt32 {
        guard pts.isValid, pts.isNumeric else { return 0 }
        // Fast path: the PTS was created at the 90kHz timescale, so `value` IS the
        // rtpTimestamp. Convert defensively if VT handed back a different scale.
        let value: Int64
        if pts.timescale == 90_000 {
            value = pts.value
        } else {
            value = CMTimeConvertScale(pts, timescale: 90_000, method: .default).value
        }
        return UInt32(truncatingIfNeeded: value)
    }

    /// P2 CORRUPTION/ARTIFACT heuristic (signal: quality). Count a corruption hit
    /// when VT returns a decode-STATUS error (badDataErr / kVTVideoDecoderBadDataErr)
    /// - VT judged the bitstream hosed, the cheap, already-computed tell for the
    /// white/purple-flash class with NO per-pixel scan. The benign info-only
    /// `frameDropped` bit (VT skipped a frame to keep up) is deliberately NOT
    /// counted - only a true decode-status error. Always-live integer add at this
    /// already-rare site (a healthy stream never hits it); off the per-frame budget.
    nonisolated static func noteCorruptionIfDecodeError(status: OSStatus) {
        guard status != noErr else { return }
        TelemetryCounters.shared.corruptionHeuristicTotal.increment()
    }

    /// P2 CONNECT-HANDSHAKE: stamp the FIRST decoded-frame instant - the close of
    /// the "established → pixels" leg + the whole cold-open total. Always-live
    /// (idempotent in P2State); off the per-frame path (the caller fires this
    /// exactly once per session, behind its own first-frame latch).
    nonisolated static func noteFirstDecodedFrameTelemetry() {
        TelemetryCounters.shared.p2.markFirstFrame(TelemetryCounters.monotonicNowNanos())
        // Resolve TRUE click-to-pixels at the SAME first-decoded-frame edge as
        // handshake_total (so the two share an endpoint); no-op without a click.
        ConnectTimingTelemetry.shared.markFirstFrame()
    }

    /// Note a fresh VT-session create for telemetry: bump the always-live recreate
    /// counter, and (gate-on only) publish the live DECODE state read back from the
    /// just-created session. Called unconditionally from
    /// `ensureDecompressionSession` so its branch stays out of that function.
    nonisolated func noteSessionCreatedTelemetry(outputPixelFormat: OSType) {
        TelemetryCounters.shared.decoderRecreateTotal.increment()
        // Gate: publish the richer state only when telemetry is on (the tracker
        // sentinel is the gate-on signal). Off-path is a single optional load.
        guard FrameTimingTracker.shared != nil else { return }
        guard let session = decompressionSession else { return }
        publishDecodeStateTelemetry(session: session, outputPixelFormat: outputPixelFormat)
    }

    /// Publish the live DECODE state (HW-decode confirmation + pixel format + bit
    /// depth + colorspace). Reads the HW-accelerated-decoder property back from the
    /// live session - VT only resolves it after create - so a silent software
    /// fallback (an OS/driver regression past our hardware REQUIRE) is surfaced
    /// rather than assumed. The colorspace key reflects the last one the decode
    /// path derived; it is refreshed on a colorspace change in `enqueueDecodedFrame`.
    private nonisolated func publishDecodeStateTelemetry(
        session: VTDecompressionSession, outputPixelFormat: OSType
    ) {
        let isTenBit = (streamVideoFormat & StreamProtocol.VIDEO_FORMAT_MASK_10BIT) != 0
        TelemetryCounters.shared.setDecodeState(TelemetryCounters.DecodeState(
            hwDecode: readHardwareDecodeConfirmation(session: session),
            codec: Self.codecLabel(for: streamVideoFormat),
            pixelFormat: fourCCString(from: outputPixelFormat),
            bitDepth: isTenBit ? 10 : 8,
            colorSpaceKey: lastColorSpaceKey ?? "pending"))
    }

    /// Map a negotiated stream-format bitmask to a codec label for telemetry.
    nonisolated static func codecLabel(for format: Int32) -> String {
        if (format & StreamProtocol.VIDEO_FORMAT_MASK_AV1) != 0 { return "av1" }
        if (format & StreamProtocol.VIDEO_FORMAT_MASK_H265) != 0 { return "hevc" }
        if (format & StreamProtocol.VIDEO_FORMAT_MASK_H264) != 0 { return "h264" }
        return "unknown"
    }

    /// Read the `UsingHardwareAcceleratedVideoDecoder` property back from the live
    /// session. The property is a CFBoolean; we read it into an
    /// `Unmanaged<CFBoolean>?` (a concrete CF class, NOT `CFTypeRef`/`AnyObject`)
    /// so forming the `valueOut` pointer doesn't trip the "pointer to
    /// Optional<AnyObject>" warning, then take the +1 reference VT returned.
    private nonisolated func readHardwareDecodeConfirmation(
        session: VTDecompressionSession
    ) -> Bool {
        var boolRef: Unmanaged<CFBoolean>?
        let status = withUnsafeMutablePointer(to: &boolRef) { pointer -> OSStatus in
            pointer.withMemoryRebound(to: CFTypeRef?.self, capacity: 1) { rebound in
                VTSessionCopyProperty(
                    session,
                    key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                    allocator: kCFAllocatorDefault,
                    valueOut: rebound)
            }
        }
        guard status == noErr, let boolRef else { return false }
        return CFBooleanGetValue(boolRef.takeRetainedValue())
    }

    /// Note a colorspace change for telemetry: refresh ONLY the colorspace key on
    /// the published DECODE state (preserving HW-decode / pixel-format / bit-depth),
    /// gate-on only. Called unconditionally from `enqueueDecodedFrame` so the gate
    /// branch stays out of that function. No-op before the first session-create
    /// publish, or when the key is unchanged.
    nonisolated func noteColorSpaceChangeTelemetry(_ key: String) {
        guard FrameTimingTracker.shared != nil else { return }
        guard var state = TelemetryCounters.shared.decodeState, state.colorSpaceKey != key else {
            return
        }
        state.colorSpaceKey = key
        TelemetryCounters.shared.setDecodeState(state)
    }
}
