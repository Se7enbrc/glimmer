// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

@testable import GlimmerEngine
import CoreMedia
import CoreVideo
import Foundation
import QuartzCore
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

    @Test func configurationLeavesThreadingToTheCodecAndReportsReadback() throws {
        var changes: [String: Bool] = [:]
        let keys = [kVTDecompressionPropertyKey_RealTime,
                    kVTDecompressionPropertyKey_MaximizePowerEfficiency,
                    kVTDecompressionPropertyKey_ThreadCount,
                    kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder]
        let fields = VideoDecoder.configureSessionProperties(
            set: { key, value in changes[key as String] = CFBooleanGetValue(value); return noErr },
            supported: { (noErr, Set(keys.map { $0 as String })) },
            read: { key in
                let name = key as String
                if name == kVTDecompressionPropertyKey_ThreadCount as String { return (noErr, NSNumber(value: 4)) }
                return (noErr, NSNumber(value: name != kVTDecompressionPropertyKey_MaximizePowerEfficiency as String))
            })
        let row = try Self.configurationRow(fields)
        #expect(changes == [kVTDecompressionPropertyKey_RealTime as String: true,
                            kVTDecompressionPropertyKey_MaximizePowerEfficiency as String: false])
        #expect(row["thread_policy"] as? String == "platform_default")
        #expect(row["thread_count_set_status"] == nil)
        #expect(row["thread_count_value"] as? Int == 4)
        #expect(row["thread_count_supported"] as? Bool == true)
        #expect(row["realtime_requested"] as? Bool == true)
        #expect(row["power_efficiency_requested"] as? Bool == false)
        #expect(row["realtime_set_status"] as? Int == 0)
        #expect(row["realtime_value"] as? Bool == true)
        #expect(row["power_efficiency_value"] as? Bool == false)
        #expect(row["hardware_value"] as? Bool == true)
    }

    @Test func configurationDoesNotInventEffectiveValuesWhenQueriesFail() throws {
        let fields = VideoDecoder.configureSessionProperties(
            set: { _, _ in kVTPropertyNotSupportedErr },
            supported: { (kVTPropertyNotSupportedErr, nil) },
            read: { _ in (kVTPropertyNotSupportedErr, NSNumber(value: 99)) })
        let row = try Self.configurationRow(fields)
        #expect(row["support_query_status"] as? Int == Int(kVTPropertyNotSupportedErr))
        #expect(row["realtime_set_status"] as? Int == Int(kVTPropertyNotSupportedErr))
        #expect(row["thread_count_read_status"] as? Int == Int(kVTPropertyNotSupportedErr))
        #expect(row["realtime_value"] == nil)
        #expect(row["thread_count_value"] == nil)
        #expect(row["hardware_value"] == nil)
        #expect(row["thread_count_supported"] == nil)
    }

    private static func configurationRow(_ fields: [String]) throws -> [String: Any] {
        let data = Data(("{" + fields.joined(separator: ",") + "}").utf8)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

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

    @Test func recoverySupersedesAlreadyQueuedDecodeWorkBeforeItCanCreateASession() async throws {
        let factory = RefusingFactory()
        let decoder = VideoDecoder(makeSession: factory.make)
        decoder.streamVideoFormat = StreamProtocol.VIDEO_FORMAT_H264
        decoder.isStreaming = true
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        decoder.decodeQueue.async {
            entered.signal()
            _ = release.wait(timeout: .now() + 5)
        }
        defer { release.signal() }
        try #require(await entered.waitAsync(for: .seconds(2)) == .success)
        _ = decoder.decodeAssembledFrame(pictureData: Data([0, 0, 0, 1, 0x65]), newSps: sps, newPps: pps,
                                         newVps: nil, isIDR: true, rtpTimestamp: 750, totalLength: 5)
        decoder.inFlightDecodeLock.withLock { decoder.lastVtDecodeFailed = true }
        decoder.statsCollector.lastDecodedFrameTime = CACurrentMediaTime() - 5
        _ = decoder.decodeAssembledFrame(pictureData: Data([0, 0, 0, 1, 0x65]), newSps: sps, newPps: pps,
                                         newVps: nil, isIDR: true, rtpTimestamp: 1_500, totalLength: 5)

        release.signal()
        await decoder.decodeQueue.drainForTest()

        #expect(factory.calls.count == 1)
        #expect(decoder.inFlightDecodeBacklog() == 0)
        #expect(decoder.decodeReservations.isEmpty)
        decoder.teardown()
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
