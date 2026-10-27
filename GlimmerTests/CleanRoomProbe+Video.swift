// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
#if canImport(GlimmerEngine)
@testable import GlimmerEngine
#else
@testable import Glimmer
#endif

extension CleanRoomProbe {
    // A stream case feeds completed RTP payloads; scan and split cases call the Annex B entry points directly.
    struct VideoInput: Codable, Sendable {
        struct Step: Codable, Sendable {
            let op: String
            let frame: UInt32
            var spi: UInt32 = 0
            var flags: UInt8 = 0
            var payload: String = ""
        }
        let format: String
        var steps: [Step] = []
        var bytes: String?
    }

    struct VideoOutput: Codable, Equatable, Sendable {
        var events: [String] = []
        var idrStart: Bool?
        var split: [String]?
    }

    static let video = area("video") { (input: VideoInput) -> VideoOutput in observeVideo(input) }

    private final class VideoRecorder: VideoDepacketizerDelegate {
        var events: [String] = []

        func depacketizerDidAssembleFrame(_ unit: DecodeUnit) {
            events.append("unit \(unit.frameNumber) type \(unit.frameType) length \(unit.fullLength) "
                + unit.buffers.map(CleanRoomProbe.describe).joined(separator: " "))
        }
        func depacketizerDetectedFrameLoss(from: Int, to: Int) { events.append("loss \(from)-\(to)") }
        func depacketizerNeedsIdr() { events.append("idr") }
        func depacketizerReceivedKeyFrame(frameNumber: Int) { events.append("key \(frameNumber)") }
    }

    static func describe(_ buffer: DecodeBuffer) -> String {
        let kind = switch buffer.kind {
        case .vps: "vps"
        case .sps: "sps"
        case .pps: "pps"
        case .picData: "pic"
        }
        return kind + ":" + hex(buffer.data)
    }

    static func observeVideo(_ input: VideoInput) -> VideoOutput {
        let format = switch input.format {
        case "hevc": StreamProtocol.VIDEO_FORMAT_H265
        case "av1": StreamProtocol.VIDEO_FORMAT_AV1_MAIN8
        default: StreamProtocol.VIDEO_FORMAT_H264
        }
        let recorder = VideoRecorder()
        let receiver = VideoDepacketizer(delegate: recorder, negotiatedVideoFormat: format, colorSpace: 0)
        var output = VideoOutput()
        if let text = input.bytes {
            let bytes = bytes(hex: text)
            output.idrStart = VideoDepacketizer.isIdrFrameStart(bytes, hevc: input.format == "hevc")
            output.split = receiver.splitAnnexBParamSets(Data(bytes)).map(describe)
        }
        for step in input.steps {
            switch step.op {
            case "lost": receiver.queueLostFrame(Int(step.frame))
            case "refresh": receiver.requestDecoderRefresh()
            default:
                receiver.process(VideoDepacketizer.CompletedPacket(
                    frameIndex: step.frame, flags: step.flags, extraFlags: 0, fecCurrentBlock: 0, fecLastBlock: 0,
                    streamPacketIndex: step.spi << 8, rtpTimestamp: step.frame,
                    presentationTimeUs: UInt64(step.frame) * 1_000, receiveTimeUs: UInt64(step.frame) * 1_000,
                    payload: bytes(hex: step.payload)[...]))
            }
        }
        output.events = recorder.events
        return output
    }
}
