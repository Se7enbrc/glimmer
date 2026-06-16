//
//  VideoDecoder+Sink.swift
//
//  The VideoSink conformance that lets the Swift-native NativeBackend drive the
//  decoder directly (setup/start/stop/cleanup/submit), plus the @unchecked
//  Sendable note. Split out of VideoDecoder.swift to keep each unit focused.
//

import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox

// MARK: - VideoSink (native backend path)

// NativeBackend wires VideoDecoder as a `VideoSink` and feeds it DecodeUnit
// value types built by RtpVideoQueue. These methods delegate to the private
// lifecycle handlers and the shared `decodeAssembledFrame` core, so the decode
// path runs the VideoToolbox state machine (decodeQueue.sync serialization,
// IDR format-desc rebuild, AVCC/OBU sample build) in one place.
//
// `@unchecked Sendable` mirrors the contract documented on VideoSink: the
// methods are all `nonisolated` and the cross-thread state they touch is guarded
// by `decodeQueue.sync` (VT state) or the single-writer/read-everywhere
// discipline (streamVideoFormat etc., set in setup before start/submit).
extension VideoDecoder: @unchecked Sendable {}

extension VideoDecoder: VideoSink {
    nonisolated public func setup(
        videoFormat: Int32, width: Int32, height: Int32, redrawRate: Int32
    ) -> Int32 {
        handleSetup(videoFormat: videoFormat, width: width, height: height, redrawRate: redrawRate)
    }

    nonisolated public func start() { handleStart() }
    nonisolated public func stop() { handleStop() }
    nonisolated public func cleanup() { handleCleanup() }

    /// The decoder's advertised capability bits — single source of truth. The
    /// RFI bits here are read by the RTSP handshake's SDP builder (via
    /// `SdpBuilder.decoderRfiCapabilities`) so the host learns we accept
    /// reference-frame-invalidation recovery (maxNumReferenceFrames=0) for the
    /// negotiated codec, instead of forcing a full IDR on every loss. We
    /// advertise HEVC + AV1 RFI (not AVC) — H.264 recovery stays full-IDR.
    nonisolated public static let rfiCapabilities: Int32 =
        StreamProtocol.CAPABILITY_REFERENCE_FRAME_INVALIDATION_HEVC
            | StreamProtocol.CAPABILITY_REFERENCE_FRAME_INVALIDATION_AV1

    nonisolated public var capabilities: Int32 {
        VideoDecoder.rfiCapabilities
    }

    /// Consume a Swift-native DecodeUnit. Walks the buffer chain (mirroring
    /// handleSubmitDecodeUnit's PLENTRY walk) into parameter sets + concatenated
    /// picture data, then hands them to the shared decode core. Returns
    /// StreamProtocol.DR_OK / DR_NEED_IDR.
    nonisolated public func submitDecodeUnit(_ unit: DecodeUnit) -> Int32 {
        guard isStreaming else { return StreamProtocol.DR_OK }

        // Stats: one decode-unit-in == one network-delivered frame;
        // fullLength is the on-the-wire byte count.
        let isIDR = (unit.frameType == StreamProtocol.FRAME_TYPE_IDR)
        statsCollector.recordReceivedFrame(bytes: Int(unit.fullLength), isIDR: isIDR)
        statsCollector.recordHostProcessingLatency(unit.frameHostProcessingLatency)

        var pictureData = Data()
        pictureData.reserveCapacity(Int(unit.fullLength))
        var newSps: Data?
        var newPps: Data?
        var newVps: Data?

        for buffer in unit.buffers {
            switch buffer.kind {
            case .sps: newSps = buffer.data
            case .pps: newPps = buffer.data
            case .vps: newVps = buffer.data
            case .picData: pictureData.append(buffer.data)
            }
        }

        return decodeAssembledFrame(
            pictureData: pictureData, newSps: newSps, newPps: newPps, newVps: newVps,
            isIDR: isIDR, rtpTimestamp: unit.rtpTimestamp, totalLength: unit.fullLength)
    }
}
