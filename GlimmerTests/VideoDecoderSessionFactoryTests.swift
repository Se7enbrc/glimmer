// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import CoreMedia
import CoreVideo
import Foundation
import Synchronization
import Testing
import VideoToolbox
@testable import Glimmer

/// Records each session request and refuses it, so no test reaches VideoToolbox.
private final class RefusingFactory: Sendable {
    struct Request {
        let width: Int32
        let pixelFormat: OSType?
        let requiresHardware: Bool
    }

    private let requests = Mutex<[Request]>([])
    var calls: [Request] { requests.withLock { $0 } }

    var make: VideoDecoder.SessionFactory {
        { [self] format, decoderSpec, attributes, _ in
            let key = kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder as String
            requests.withLock {
                $0.append(Request(width: CMVideoFormatDescriptionGetDimensions(format).width,
                                  pixelFormat: attributes[kCVPixelBufferPixelFormatTypeKey as String] as? OSType,
                                  requiresHardware: decoderSpec[key] as? Bool == true))
            }
            return (kVTVideoDecoderNotAvailableNowErr, nil)
        }
    }
}

@MainActor
struct VideoDecoderSessionFactoryTests {
    // A 1280x720 High-profile SPS and its PPS, start codes included as they arrive.
    private let sps = Data([0, 0, 0, 1, 0x67, 0x64, 0x00, 0x1F, 0xAC, 0xD9, 0x40, 0x50, 0x05, 0xBB, 0x01, 0x10,
                            0x00, 0x00, 0x03, 0x00, 0x10, 0x00, 0x00, 0x03, 0x03, 0xC0, 0xF1, 0x83, 0x19, 0x60])
    private let pps = Data([0, 0, 0, 1, 0x68, 0xEB, 0xE3, 0xCB, 0x22, 0xC0])

    @Test(arguments: [
        (StreamProtocol.VIDEO_FORMAT_H264, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        (StreamProtocol.VIDEO_FORMAT_H265_MAIN10, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange),
        (StreamProtocol.VIDEO_FORMAT_H265_REXT8_444, kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange),
        (StreamProtocol.VIDEO_FORMAT_AV1_HIGH10_444, kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange)
    ])
    func sessionAsksForTheNegotiatedOutputOnHardware(format: Int32, pixelFormat: OSType) throws {
        let factory = RefusingFactory()
        let decoder = VideoDecoder(makeSession: factory.make)
        decoder.streamVideoFormat = format
        decoder.formatDescription = try VideoDecoderHDRTests.formatDescription()
        #expect(!decoder.ensureDecompressionSession())
        #expect(factory.calls.map(\.pixelFormat) == [pixelFormat])
        #expect(factory.calls.map(\.requiresHardware) == [true])
    }

    @Test func aRefusedSessionReleasesItsCallbackRetain() throws {
        let factory = RefusingFactory()
        weak var released: VideoDecoder?
        do {
            let decoder = VideoDecoder(makeSession: factory.make)
            decoder.formatDescription = try VideoDecoderHDRTests.formatDescription()
            #expect(!decoder.ensureDecompressionSession())
            #expect(decoder.outputCallbackRefcon == nil)
            released = decoder
        }
        #expect(released == nil)
    }

    @Test func noFormatDescriptionMeansNoSessionRequest() {
        let factory = RefusingFactory()
        #expect(!VideoDecoder(makeSession: factory.make).ensureDecompressionSession())
        #expect(factory.calls.isEmpty)
    }

    /// New parameter sets on an IDR rebuild the format and ask for a session; a later
    /// P-frame with no session and no parameter sets asks for none.
    @Test func parameterSetsOnAnIDRRequestASessionAndPFramesDoNot() async {
        let factory = RefusingFactory()
        let decoder = VideoDecoder(makeSession: factory.make)
        decoder.streamVideoFormat = StreamProtocol.VIDEO_FORMAT_H264
        decoder.isStreaming = true
        _ = decoder.decodeAssembledFrame(pictureData: Data([0, 0, 0, 1, 0x65]), newSps: sps, newPps: pps,
                                         newVps: nil, isIDR: true, rtpTimestamp: 0, totalLength: 5)
        await decoder.decodeQueue.drainForTest()
        #expect(factory.calls.map(\.width) == [1_280])
        #expect(decoder.spsData == sps.dropFirst(4))
        #expect(decoder.statsCollector.decoderDropCount() == 1)

        _ = decoder.decodeAssembledFrame(pictureData: Data([0, 0, 0, 1, 0x41]), newSps: nil, newPps: nil,
                                         newVps: nil, isIDR: false, rtpTimestamp: 1, totalLength: 5)
        await decoder.decodeQueue.drainForTest()
        #expect(factory.calls.count == 1)
    }

    @Test func createCauseFollowsThePriorSessionAndDimensions() {
        let hd = CMVideoDimensions(width: 1_920, height: 1_080)
        let uhd = CMVideoDimensions(width: 3_840, height: 2_160)
        typealias Decoder = VideoDecoder
        #expect(Decoder.sessionCreateCause(hadPriorSession: false, priorDims: hd, newDims: uhd) == .firstCreate)
        #expect(Decoder.sessionCreateCause(hadPriorSession: true, priorDims: hd, newDims: uhd) == .resolution)
        #expect(Decoder.sessionCreateCause(hadPriorSession: true, priorDims: hd, newDims: hd) == .colorspace)
        #expect(Decoder.sessionCreateCause(hadPriorSession: true, priorDims: nil, newDims: hd) == .colorspace)
    }
}
