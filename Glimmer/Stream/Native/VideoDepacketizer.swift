//
//  VideoDepacketizer.swift
//
//  The Swift-native depacketizer: turns the in-order, FEC-reconstructed RTP
//  video packets that RtpVideoQueue produces into complete access units
//  (DecodeUnit value types) and hands them to the injected VideoSink. Ports
//  VideoDepacketizer.c (processRtpPayload + reassembleFrame), scoped to the AV1
//  path our live host negotiates (AV1, encEnabled=0).
//
//  Transport ported from moonlight-common-c (GPLv3); see CREDITS.md.
//
//  AV1 SPECIFICS (the load-bearing subset, VideoDepacketizer.c:1027-1069):
//   - The whole access unit is ONE BUFFER_TYPE_PICDATA blob (sequence-header OBU
//     inline); no SPS/PPS/VPS split (getBufferFlags returns PICDATA for non
//     H.264/HEVC, c:558-560). VideoDecoder's AV1 rebuild parses the seq header
//     out of pictureData itself.
//   - Frame TYPE is read from the frame-header byte data[offset+3] (2=IDR),
//     NOT by parsing the bitstream (c:861-868). VT needs frameType=IDR to build
//     the format description.
//   - On the LAST packet of a frame, the payload MUST be truncated to
//     (lastPacketPayloadLength - frameHeaderSize) - AV1 is intolerant of the
//     FEC trailing-zero padding that H.264/HEVC Annex-B tolerates (c:1030-1041).
//   - Frame-header length is version + byte0 dependent (c:914-965). For our
//     target (>= 7.1.450): data[0]==0x01 ⇒ 8 bytes, data[0]==0x81 ⇒ 44 bytes.
//
//  H.264/HEVC (Annex-B) SPECIFICS (c:974-1025 + the slow-path NAL routing):
//   - The accumulated AU is an Annex-B elementary stream. FEC trailing-zero
//     padding on the last packet is TOLERATED (no payload-length truncation -
//     that field is AV1-only on the wire), matching the C path; the decoder's
//     Annex-B→AVCC rewrite carries the zeros inside the final NAL, which VT
//     accepts (same as moonlight-ios).
//   - IDR detection does NOT trust the frame-header type byte (c:861-868 takes
//     the header's word only for non-H.264/HEVC): a frame is IDR iff its first
//     payload starts with the 4-byte start code + SPS (H.264) / VPS (HEVC) -
//     the isIdrFrameStart port. Sunshine rides the param sets on every IDR.
//   - On IDR reassembly the leading VPS/SPS/PPS NALs are split into their own
//     DecodeBuffers (the C slow path's getBufferFlags routing); everything
//     else stays picture data in arrival order. P-frames skip the scan.

import Foundation

/// Callbacks the depacketizer fires up into the receiver / control loop.
protocol VideoDepacketizerDelegate: AnyObject {
    /// A complete access unit is ready to decode.
    func depacketizerDidAssembleFrame(_ unit: DecodeUnit)
    /// Detected a corrupt / discontinuous frame; host should be told (RFI or
    /// IDR) so it resends. `from`/`to` are the RFI window (frame numbers).
    func depacketizerDetectedFrameLoss(from: Int, to: Int)
    /// We need a fresh IDR (unrecoverable while waiting for one).
    func depacketizerNeedsIdr()
    /// A key frame was successfully received (clears the "waiting for IDR"
    /// state on the receive side / watchdog).
    func depacketizerReceivedKeyFrame(frameNumber: Int)
}

final class VideoDepacketizer {
    private static let cat = "NativeVideo"

    // Flags (Video.h:21-23).
    private static let FLAG_CONTAINS_PIC_DATA: UInt8 = 0x1
    private static let FLAG_EOF: UInt8 = 0x2
    private static let FLAG_SOF: UInt8 = 0x4
    private static let EXTRA_FLAG_LTR: UInt8 = 0x1

    // Frame types (matches StreamProtocol).
    private static let FRAME_TYPE_PFRAME: Int32 = 0
    private static let FRAME_TYPE_IDR: Int32 = 1

    private weak var delegate: VideoDepacketizerDelegate?
    private let negotiatedVideoFormat: Int32
    private let appVersionQuad: [Int32]
    private let colorSpace: Int32

    // The 16-byte NV header is stripped by RtpVideoQueue before handing us the
    // payload, so dataOffset accounting lives there; here we only see the
    // per-packet metadata + payload bytes.

    // Depacketizer state (mirrors the C file-scope statics).
    // nextFrameNumber starts at 1 (host's first frameIndex is 1, matching
    // RtpVideoQueue.currentFrameNumber). lastPacketInStream starts at UINT32_MAX
    // so the first packet's contiguity check (expectedNext = u24(last+1) = 0)
    // accepts a stream that starts at SPI 0 - initializing to 0 instead makes
    // expectedNext = 1 and DROPS the first IDR frame (VideoDepacketizer.c:65,70).
    private var nextFrameNumber: UInt32 = 1
    private var startFrameNumber: UInt32 = 0
    private var lastPacketInStream: UInt32 = .max
    private var decodingFrame = false
    private var waitingForIdrFrame = true
    // RFI recovery state (VideoDepacketizer.c file-scope statics). The client
    // RFI accept-path is always armed (strictIdrFrameWait=false): after the
    // first IDR is processed, a loss is recovered with a host post-invalidation
    // recovery frame (header type 4/5), not a full IDR. Whether the HOST
    // actually sends those recovery frames is negotiated in the SDP - RFI is
    // advertised (maxNumReferenceFrames=0) only when the host offered RFI and
    // our decoder supports it for the negotiated codec (VideoDecoder
    // .rfiCapabilities = HEVC|AV1; see SdpBuilder.referenceFrameInvalidationActive).
    // If the host ignores it and keeps sending IDRs, this state machine still
    // accepts them - RFI degrades gracefully to full-IDR recovery.
    private var waitingForRefInvalFrame = false        // C:14
    private var waitingForNextSuccessfulFrame = false  // C:12
    private var idrFrameProcessed = false              // C:26
    private let strictIdrFrameWait = false             // C:80 (client RFI accept-path armed)
    private var consecutiveFrameDrops = 0              // C:31
    private static let CONSECUTIVE_DROP_LIMIT = 120    // C:30 (Video.h)
    private var syntheticPtsBaseUs: UInt64 = 0

    // Per-frame accumulation.
    private var frameType: Int32 = VideoDepacketizer.FRAME_TYPE_PFRAME
    /// True iff THIS frame is a host post-invalidation RECOVERY frame (type 4/5)
    /// that cleared an outstanding RFI wait - the frame that resolves an RFI
    /// round-trip (signal: IDR-RTT). Set in parseFrameHeader, read + cleared in
    /// reassembleFrame. Telemetry-only; does not affect decode behavior.
    private var frameIsRfiRecovery = false
    private var frameHostProcessingLatency: UInt16 = 0
    private var lastPacketPayloadLength: UInt16 = 0
    private var firstPacketReceiveTimeUs: UInt64 = 0
    private var firstPacketPresentationTimeUs: UInt64 = 0
    private var firstPacketRtpTimestamp: UInt32 = 0
    private var nalChain = Data()

    // Diagnostics latches.
    private var loggedFirstFrame = false
    private var loggedFirstIdr = false

    init(delegate: VideoDepacketizerDelegate, negotiatedVideoFormat: Int32,
         appVersionQuad: [Int32], colorSpace: Int32) {
        self.delegate = delegate
        self.negotiatedVideoFormat = negotiatedVideoFormat
        self.appVersionQuad = appVersionQuad
        self.colorSpace = colorSpace
    }

    private var isAV1: Bool {
        (negotiatedVideoFormat & StreamProtocol.VIDEO_FORMAT_MASK_AV1) != 0
    }
    private var isHEVC: Bool {
        (negotiatedVideoFormat & StreamProtocol.VIDEO_FORMAT_MASK_H265) != 0
    }

    // MARK: - 24-bit / 32-bit wraparound helpers (Limelight-internal.h:72-78)

    private static let UINT24_MAX: UInt32 = 0xFF_FFFF
    @inline(__always) private static func u24(_ x: UInt32) -> UInt32 { x & UINT24_MAX }
    @inline(__always) private static func isBefore24(_ x: UInt32, _ y: UInt32) -> Bool {
        u24(x &- y) > (UINT24_MAX / 2)
    }
    @inline(__always) private static func isBefore32(_ x: UInt32, _ y: UInt32) -> Bool {
        (x &- y) > (UInt32.max / 2)
    }

    // MARK: - Packet metadata (one completed RTP/NV packet)

    /// A single completed packet handed down by RtpVideoQueue, in frame order.
    /// `payload` is the bytes AFTER the 16-byte NV header.
    struct CompletedPacket {
        let frameIndex: UInt32
        let flags: UInt8
        let extraFlags: UInt8
        let fecCurrentBlock: UInt8
        let fecLastBlock: UInt8
        var streamPacketIndex: UInt32   // already 24-bit-masked by the queue? no - we mask here
        let rtpTimestamp: UInt32
        let presentationTimeUs: UInt64
        let receiveTimeUs: UInt64
        let payload: [UInt8]
    }

    // MARK: - Process one packet (processRtpPayload, AV1 subset)

    func process(_ pkt: CompletedPacket) {
        // Mask the top 8 bits from the SPI (c:758-759).
        let streamPacketIndex = Self.u24(pkt.streamPacketIndex >> 8)

        let flags = pkt.flags
        let frameIndex = pkt.frameIndex
        let firstPacket = Self.isFirstPacket(flags: flags, fecBlock: pkt.fecCurrentBlock)
        let lastPacket = (flags & Self.FLAG_EOF) != 0 && pkt.fecCurrentBlock == pkt.fecLastBlock

        // Drop packets from a previously corrupt frame (c:778).
        if Self.isBefore32(frameIndex, nextFrameNumber) {
            return
        }

        // Corrupt-frame guard via streamPacketIndex contiguity (c:785-798).
        let expectedNext = Self.u24(lastPacketInStream &+ 1)
        if Self.isBefore24(streamPacketIndex, expectedNext)
            || ((flags & Self.FLAG_SOF) == 0 && streamPacketIndex != expectedNext) {
            Diag.warn("NativeVideo depacketizer corrupt frame \(frameIndex) "
                + "(spi=\(streamPacketIndex) expected=\(expectedNext))", Self.cat)
            // P2 CORRUPTION/ARTIFACT heuristic (signal: quality): a stream-packet-
            // index DISCONTINUITY orphaned the reference chain - the on-the-wire
            // tell for the white/purple-flash class (a reference-broken frame would
            // reach VT without this guard). Cheap integer add at the already-rare
            // corrupt-frame site; no per-pixel scan.
            TelemetryCounters.shared.corruptionHeuristicTotal.increment()
            decodingFrame = false
            nextFrameNumber = frameIndex &+ 1
            dropFrameState()
            if waitingForIdrFrame {
                delegate?.depacketizerNeedsIdr()
            } else {
                delegate?.depacketizerDetectedFrameLoss(from: Int(startFrameNumber), to: Int(frameIndex))
            }
            return
        }

        if firstPacket {
            beginFrame(pkt: pkt, frameIndex: frameIndex)
        }

        lastPacketInStream = streamPacketIndex

        var payload = pkt.payload
        var frameHeaderSize = 0

        if firstPacket && !payload.isEmpty {
            frameHeaderSize = parseFrameHeader(&payload, frameIndex: frameIndex)
            if frameHeaderSize < 0 {
                // Header parse failed; drop the frame.
                decodingFrame = false
                nextFrameNumber = frameIndex &+ 1
                dropFrameState()
                return
            }
            // Skip past the frame header.
            if payload.count >= frameHeaderSize {
                payload.removeFirst(frameHeaderSize)
            }
        }

        if isAV1 {
            if lastPacket {
                // Truncate to the exact AV1 length (c:1030-1041). The payload
                // length includes the frame header, so subtract it.
                let plen = Int(lastPacketPayloadLength)
                if plen > frameHeaderSize && (plen - frameHeaderSize) <= payload.count {
                    payload = Array(payload.prefix(plen - frameHeaderSize))
                } else {
                    Diag.warn("NativeVideo invalid last payload length frame \(frameIndex): "
                        + "plen=\(plen) hdr=\(frameHeaderSize) have=\(payload.count)", Self.cat)
                    decodingFrame = false
                    nextFrameNumber = frameIndex &+ 1
                    dropFrameState()
                    if waitingForIdrFrame {
                        delegate?.depacketizerNeedsIdr()
                    } else {
                        delegate?.depacketizerDetectedFrameLoss(from: Int(startFrameNumber), to: Int(frameIndex))
                    }
                    return
                }
            }
            nalChain.append(contentsOf: payload)
        } else {
            // H.264/HEVC Annex-B path. IDR detection by NAL inspection, not
            // the header type byte (see file header). No last-packet
            // truncation: Annex-B tolerates the FEC trailing-zero padding.
            if firstPacket && Self.isIdrFrameStart(payload, hevc: isHEVC) {
                frameType = Self.FRAME_TYPE_IDR
                waitingForIdrFrame = false
                waitingForNextSuccessfulFrame = false
            }
            nalChain.append(contentsOf: payload)
        }

        if lastPacket {
            finishFrame(pkt: pkt, frameIndex: frameIndex)
        }
    }

    /// First-packet-of-frame setup, split out of `process`: gap detection,
    /// frame-state init, and PTS-base synthesis (c:805-844).
    private func beginFrame(pkt: CompletedPacket, frameIndex: UInt32) {
        // Make sure this is the next consecutive frame (c:805-826).
        if Self.isBefore32(nextFrameNumber, frameIndex) {
            Diag.warn("NativeVideo network dropped frames \(nextFrameNumber)..\(frameIndex - 1)", Self.cat)
            nextFrameNumber = frameIndex
            // C:821 - wait for the next complete frame before re-requesting
            // recovery (network-recovery approximation).
            waitingForNextSuccessfulFrame = true
            dropFrameState()
        }

        decodingFrame = true
        frameType = Self.FRAME_TYPE_PFRAME
        frameIsRfiRecovery = false
        firstPacketReceiveTimeUs = pkt.receiveTimeUs

        // Synthesize a PTS base if the host doesn't send one (c:833-844).
        if syntheticPtsBaseUs == 0 {
            syntheticPtsBaseUs = pkt.receiveTimeUs
        }
        if pkt.presentationTimeUs == 0 && frameIndex > 0 {
            firstPacketPresentationTimeUs = pkt.receiveTimeUs - syntheticPtsBaseUs
        } else {
            firstPacketPresentationTimeUs = pkt.presentationTimeUs
        }
        firstPacketRtpTimestamp = pkt.rtpTimestamp
    }

    /// Last-packet-of-frame handling, split out of `process`: close the frame
    /// and either drop it through the recovery gate or hand it to reassembly.
    private func finishFrame(pkt: CompletedPacket, frameIndex: UInt32) {
        decodingFrame = false
        nextFrameNumber = frameIndex &+ 1

        // Recovery-gate (c:1078-1100). parseFrameHeader already cleared
        // waitingForIdrFrame on a type-2 IDR and waitingForRefInvalFrame on
        // a type-4/5 host recovery frame, so a genuine recovery frame falls
        // THROUGH this gate and reaches reassembleFrame. Anything else while
        // we're still waiting is dropped (and an IDR/RFI re-requested).
        if waitingForIdrFrame || waitingForRefInvalFrame {
            if waitingForIdrFrame {
                // c:1080-1088 - only re-request after the first clean frame
                // post-loss, to avoid IDR-spamming an unstable network.
                if waitingForNextSuccessfulFrame {
                    delegate?.depacketizerNeedsIdr()
                }
            } else {
                // c:1090-1094 - still need an RFI frame; report the loss
                // window and drop this one.
                delegate?.depacketizerDetectedFrameLoss(from: Int(startFrameNumber), to: Int(frameIndex))
            }
            waitingForNextSuccessfulFrame = false   // c:1097
            dropFrameState()                        // c:1098
            return
        }

        reassembleFrame(frameIndex: frameIndex,
                        isLTR: (pkt.extraFlags & Self.EXTRA_FLAG_LTR) != 0)
    }

    // MARK: - Frame header parse (c:851-972)

    /// Returns the frame header size to skip, or -1 on parse failure.
    private func parseFrameHeader(_ payload: inout [UInt8], frameIndex: UInt32) -> Int {
        guard payload.count >= 4 else { return -1 }

        // Frame type from data[offset+3] (offset==0 here) (c:857-887).
        let typeByte = payload[3]
        switch typeByte {
        case 1:  // Normal P-frame
            break
        case 2:  // IDR
            // For non-H.264/HEVC we trust the header byte (c:861-868).
            if isAV1 {
                waitingForIdrFrame = false
                waitingForNextSuccessfulFrame = false   // c:866
                frameType = Self.FRAME_TYPE_IDR
            }
            fallthrough                                 // c:869 - into 4/5
        case 4, 5:  // intra-refresh / P-frame with RFI
            // Host recovery frame after an RFI request: accept it by clearing
            // the RFI wait so it falls through the lastPacket gate (c:872-878).
            if waitingForRefInvalFrame {
                Diag.notice("NativeVideo post-invalidation recovery frame \(frameIndex) "
                    + "(\(typeByte == 5 ? "P" : "I")-frame)", Self.cat)
                waitingForRefInvalFrame = false
                waitingForNextSuccessfulFrame = false
                // P2 IDR/RFI ROUND-TRIP: this recovery frame resolves an RFI
                // request (the IDR path resolves in the receiver via unit.isIDR).
                frameIsRfiRecovery = true
            }
        case 104:   // Sunshine hardcoded header
            break
        default:
            Diag.warn("NativeVideo unrecognized frame type byte \(typeByte) frame \(frameIndex)", Self.cat)
        }

        // Sunshine host processing latency = u16 LE at offset+1 (c:899-903).
        if payload.count >= 3 {
            frameHostProcessingLatency = UInt16(payload[1]) | (UInt16(payload[2]) << 8)
        }

        // AV1 (non-H264/HEVC) lastPacketPayloadLength = u16 LE at offset+4
        // (c:908-912).
        if isAV1 && payload.count >= 6 {
            lastPacketPayloadLength = UInt16(payload[4]) | (UInt16(payload[5]) << 8)
        }

        return frameHeaderSize(byte0: payload[0])
    }

    /// Version + byte0 dependent header length (c:914-965).
    private func frameHeaderSize(byte0: UInt8) -> Int {
        let quad = appVersionQuad
        func atLeast(_ major: Int32, _ minor: Int32, _ patch: Int32) -> Bool {
            if quad.count < 3 { return false }
            if quad[0] != major { return quad[0] > major }
            if quad[1] != minor { return quad[1] > minor }
            return quad[2] >= patch
        }

        if atLeast(7, 1, 450) {
            return byte0 == 0x01 ? 8 : 44
        } else if atLeast(7, 1, 446) {
            return byte0 == 0x01 ? 8 : 41
        } else if atLeast(7, 1, 415) {
            return byte0 == 0x01 ? 8 : 24
        } else if atLeast(7, 1, 350) {
            return 8
        } else if atLeast(7, 1, 320) {
            return 12
        } else if atLeast(5, 0, 0) {
            return 8
        } else {
            return 0
        }
    }

    // MARK: - Reassemble (c:468-551)

    private func reassembleFrame(frameIndex: UInt32, isLTR: Bool) {
        guard !nalChain.isEmpty else { return }

        // AV1: the whole AU is one PICDATA buffer. H.264/HEVC: same for
        // P-frames; IDR frames get their leading VPS/SPS/PPS split out below.
        let fullLength = Int32(nalChain.count)

        // IDR forcing: first buffer is always PICDATA for AV1, so the IDR
        // decision is purely from the frame-header byte we set in frameType.
        var ft = frameType
        if ft == Self.FRAME_TYPE_IDR {
            delegate?.depacketizerReceivedKeyFrame(frameNumber: Int(frameIndex))
            if !loggedFirstIdr {
                loggedFirstIdr = true
                Diag.notice("NativeVideo first IDR assembled (frame \(frameIndex), \(fullLength) bytes)", Self.cat)
            }
            // C:296 - an IDR has been processed; enable RFI mode so a future
            // loss recovers via a host RFI (type 4/5) frame instead of forcing
            // a full IDR. (C sets this on DR_OK from the decoder; the native
            // path has no decode-result feedback into the depacketizer, so we
            // mark it once the IDR is successfully assembled and submitted.)
            idrFrameProcessed = true
        } else {
            ft = Self.FRAME_TYPE_PFRAME
        }

        // hdrActive/colorspace pass-through is CORRECT here, not a gap: on
        // this client HDR engages entirely through the control channel (host
        // 0x010e → EnetControlChannel.onHdrMode → VideoDecoder.setHDR, with
        // mastering metadata via backend.hdrMetadata()), and NO consumer reads
        // DecodeUnit.hdrActive or .colorspace - the decoder derives its
        // colorspace from the bitstream + setHDR state. The fields exist for
        // protocol parity with the C DECODE_UNIT; mirroring lastHdrEnabled
        // into them would duplicate cross-thread state nobody reads. The
        // negotiated colorSpace passes through as-is.
        let hdrActive = false
        let cs = colorSpace

        // Buffer chain: H.264/HEVC IDRs carry their parameter sets inline at
        // the head of the AU - split them into typed buffers (the C slow
        // path's getBufferFlags routing) so the decoder rebuilds its format
        // description; everything else ships as one picData buffer.
        let buffers: [DecodeBuffer]
        if !isAV1 && ft == Self.FRAME_TYPE_IDR {
            buffers = splitAnnexBParamSets(nalChain)
        } else {
            buffers = [DecodeBuffer(kind: .picData, data: nalChain)]
        }

        let unit = DecodeUnit(
            frameNumber: Int32(truncatingIfNeeded: frameIndex),
            frameType: ft,
            fullLength: fullLength,
            frameHostProcessingLatency: frameHostProcessingLatency,
            receiveTimeUs: firstPacketReceiveTimeUs,
            enqueueTimeUs: Self.nowUs(),
            presentationTimeUs: firstPacketPresentationTimeUs,
            rtpTimestamp: firstPacketRtpTimestamp,
            hdrActive: hdrActive,
            colorspace: cs,
            buffers: buffers)

        if !loggedFirstFrame {
            loggedFirstFrame = true
            Diag.notice("NativeVideo first complete frame assembled "
                + "(frame \(frameIndex), type=\(ft), \(fullLength) bytes)", Self.cat)
        }

        // P2 IDR/RFI ROUND-TRIP (signal: IDR-RTT): an RFI request is resolved by a
        // host post-invalidation RECOVERY frame (type 4/5), which is forwarded as a
        // P-frame - so it's not caught by the receiver's IDR-path resolve. Resolve
        // it here for the recovery case only (IDR resolves in the receiver via
        // unit.isIDR), gate-on so it pairs with the gate-on arm and costs nothing
        // off. An unsolicited recovery (no request pending) resolves to nil.
        if frameIsRfiRecovery, ft != Self.FRAME_TYPE_IDR,
           let tracker = FrameTimingTracker.shared,
           let roundTripMs = TelemetryCounters.shared.p2.resolveIdrArrival(
                TelemetryCounters.monotonicNowNanos()) {
            TelemetryCounters.shared.idrRoundTripMatchedTotal.increment()
            tracker.recordIdrRoundTrip(frameIndex: unit.frameNumber, roundTripMs: roundTripMs)
        }
        frameIsRfiRecovery = false

        // Clear NAL state before the (possibly re-entrant) submit.
        nalChain = Data()
        frameHostProcessingLatency = 0

        delegate?.depacketizerDidAssembleFrame(unit)

        // C:545 - a frame was submitted successfully; clear the drop backstop
        // so it only fires after sustained, unbroken loss.
        consecutiveFrameDrops = 0

        // Move the RFI window forward.
        startFrameNumber = nextFrameNumber
    }

    /// Force the depacketizer to drop-and-hold until the next decodable IDR,
    /// then request that IDR once. Port of moonlight's requestDecoderRefresh
    /// (VideoDepacketizer.c:717-732): set waitingForIdrFrame + dropFrameState +
    /// (in C) flush the decode-unit queue + LiRequestIdrFrame.
    ///
    /// The native path has no separate decode-unit queue - the depacketizer
    /// emits straight into the VideoSink - so "flush the decode queue" maps to:
    /// stop emitting. With waitingForIdrFrame=true the lastPacket recovery-gate
    /// (process(_:):266-281) drops EVERY subsequent assembled frame until a real
    /// type-2 IDR arrives, so no reference-broken P-frame ever reaches
    /// decodeAssembledFrame/VideoToolbox (the white/purple HDR corruption). The
    /// IDR request is coalesced by EnetControlChannel, so the bounded-backlog
    /// overflow that triggers this requests exactly one IDR per loss event
    /// instead of one per dropped/garbage frame.
    ///
    /// MUST be called on the receive thread that owns depacketizer state (the
    /// VideoSink → depacketizerDidAssembleFrame path already runs there), so the
    /// state mutation is safely serialized with process(_:) - mirroring why
    /// moonlight defers its own drop via dropStatePending rather than nuking
    /// state mid-frame from another thread.
    func requestDecoderRefresh() {
        waitingForIdrFrame = true   // c:719
        dropFrameState()            // c:722 (re-arms the recovery gate)
        // c:731 - request the IDR (coalesced on the send side to one per event).
        delegate?.depacketizerNeedsIdr()
    }

    /// Called by RtpVideoQueue when it gives up on a frame (notifyFrameLost).
    /// Bridges to the control-stream RFI/IDR path.
    func queueLostFrame(_ frameNumber: Int) {
        // C notifyFrameLost (c:1132-1156): drop+re-arm state first, then - only
        // if dropFrameState determined RFI is usable - advance nextFrameNumber
        // and send the loss/RFI notification.
        TelemetryCounters.shared.frameLossTotal.increment()
        dropFrameState()                                   // c:1137
        if !waitingForIdrFrame {                           // c:1140 - RFI usable
            // Advance the frame number since we won't expect this one anymore.
            nextFrameNumber = UInt32(truncatingIfNeeded: frameNumber) &+ 1   // c:1151
            delegate?.depacketizerDetectedFrameLoss(from: Int(startFrameNumber), to: frameNumber)
        }
        // else: waiting for IDR - dropFrameState's backstop already requested an
        // IDR if the drop limit fired (matches C, which only RFIs in this path).
    }

    // MARK: - State drop

    /// Cleanup frame state and re-arm a recovery gate (C dropFrameState
    /// c:99-131). This is the load-bearing port: after a loss it requires
    /// either a fresh IDR (non-RFI / never-seen-IDR / explicit-IDR-wait) or an
    /// RFI recovery frame, and force-requests an IDR after CONSECUTIVE_DROP_LIMIT
    /// sustained drops as a catch-all backstop.
    private func dropFrameState() {
        nalChain = Data()
        frameHostProcessingLatency = 0
        decodingFrame = false

        // C:106-113 - pick which recovery frame we now require.
        if strictIdrFrameWait || !idrFrameProcessed || waitingForIdrFrame {
            // Need an IDR: non-RFI mode, never received an IDR, or explicit wait.
            waitingForIdrFrame = true
        } else {
            // RFI is usable.
            waitingForRefInvalFrame = true
        }

        // C:116-128 - catch-all force-IDR backstop after sustained loss.
        consecutiveFrameDrops += 1
        if consecutiveFrameDrops == Self.CONSECUTIVE_DROP_LIMIT {
            Diag.warn("NativeVideo reached consecutive drop limit; forcing IDR", Self.cat)
            consecutiveFrameDrops = 0
            waitingForIdrFrame = true
            delegate?.depacketizerNeedsIdr()   // -> enet.requestIdrFrame()
        }
    }

    // MARK: - H.264/HEVC Annex-B helpers

    /// isIdrFrameStart port: the frame's first payload must open with the
    /// 4-byte start code (NV's frame-start marker; 3-byte means mid-frame)
    /// followed by SPS (H.264, nal_unit_type 7) or VPS (HEVC, type 32) -
    /// the host rides parameter sets on every IDR.
    private static func isIdrFrameStart(_ payload: [UInt8], hevc: Bool) -> Bool {
        guard payload.count >= 5,
              payload[0] == 0, payload[1] == 0, payload[2] == 0, payload[3] == 1
        else { return false }
        if hevc {
            return (payload[4] >> 1) & 0x3F == 32      // H265_NAL_TYPE_VPS
        }
        return payload[4] & 0x1F == 7                  // H264_NAL_TYPE_SPS
    }

    /// Split an Annex-B access unit into typed DecodeBuffers: VPS/SPS/PPS
    /// NALs (H.264: 7/8; HEVC: 32/33/34) each become their own buffer -
    /// start code kept; the decoder strips it - and every other NAL (SEI,
    /// slices) stays in ONE picData buffer in arrival order. Runs only on
    /// IDR frames, so the per-byte scan is off the steady-state path.
    private func splitAnnexBParamSets(_ au: Data) -> [DecodeBuffer] {
        let bytes = [UInt8](au)
        var vps: Data?, sps: Data?, pps: Data?
        var picData = Data()
        picData.reserveCapacity(bytes.count)

        // NAL boundaries: each starts at a 00 00 01 / 00 00 00 01 start code
        // and runs to the next start code (or end of AU).
        var starts: [Int] = []           // index OF the start code
        var i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0 && bytes[i + 1] == 0 {
                if bytes[i + 2] == 1 {
                    starts.append(i); i += 3; continue
                }
                if i + 3 < bytes.count && bytes[i + 2] == 0 && bytes[i + 3] == 1 {
                    starts.append(i); i += 4; continue
                }
            }
            i += 1
        }
        guard !starts.isEmpty else {
            return [DecodeBuffer(kind: .picData, data: au)]
        }

        for (idx, start) in starts.enumerated() {
            let end = idx + 1 < starts.count ? starts[idx + 1] : bytes.count
            let scLen = bytes[start + 2] == 1 ? 3 : 4
            let headerIndex = start + scLen
            guard headerIndex < end else { continue }
            let nal = au.subdata(in: start..<end)
            let kind: DecodeBuffer.Kind
            if isHEVC {
                switch (bytes[headerIndex] >> 1) & 0x3F {
                case 32: kind = .vps
                case 33: kind = .sps
                case 34: kind = .pps
                default: kind = .picData
                }
            } else {
                switch bytes[headerIndex] & 0x1F {
                case 7: kind = .sps
                case 8: kind = .pps
                default: kind = .picData
                }
            }
            switch kind {
            case .vps: vps = nal
            case .sps: sps = nal
            case .pps: pps = nal
            case .picData: picData.append(nal)
            }
        }

        var out: [DecodeBuffer] = []
        if let vps { out.append(DecodeBuffer(kind: .vps, data: vps)) }
        if let sps { out.append(DecodeBuffer(kind: .sps, data: sps)) }
        if let pps { out.append(DecodeBuffer(kind: .pps, data: pps)) }
        out.append(DecodeBuffer(kind: .picData, data: picData))
        return out
    }

    // MARK: - Helpers

    /// isFirstPacket (c:735-741): (flags without PIC) == (SOF|EOF) or == SOF,
    /// AND fecBlock == 0.
    private static func isFirstPacket(flags: UInt8, fecBlock: UInt8) -> Bool {
        let masked = flags & ~FLAG_CONTAINS_PIC_DATA
        return (masked == (FLAG_SOF | FLAG_EOF) || masked == FLAG_SOF) && fecBlock == 0
    }

    private static func nowUs() -> UInt64 {
        UInt64(DispatchTime.now().uptimeNanoseconds / 1000)
    }
}
