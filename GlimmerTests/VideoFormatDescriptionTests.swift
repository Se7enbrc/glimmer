//
//  VideoFormatDescriptionTests.swift
//
//  Format descriptions built from real x264/x265 parameter sets and AV1 sequence headers.
//

import CoreMedia
import Foundation
import Testing

@testable import Glimmer

@MainActor
struct VideoFormatDescriptionTests {

    // 320x240 High profile SPS and its PPS, as x264 emits them (no start codes).
    static let h264SPS = Data([
        0x67, 0x64, 0x00, 0x0D, 0xAC, 0xD9, 0x41, 0x41, 0xFB, 0x01, 0x10, 0x00, 0x00,
        0x03, 0x00, 0x10, 0x00, 0x00, 0x03, 0x03, 0x20, 0xF1, 0x42, 0x99, 0x60
    ])
    static let h264PPS = Data([0x68, 0xEB, 0xE3, 0xCB, 0x22, 0xC0])

    // 320x240 Main profile VPS, SPS and PPS, as x265 emits them.
    static let hevcVPS = Data([
        0x40, 0x01, 0x0C, 0x01, 0xFF, 0xFF, 0x01, 0x60, 0x00, 0x00, 0x03, 0x00,
        0x90, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x00, 0x3C, 0x95, 0x98, 0x09
    ])
    static let hevcSPS = Data([
        0x42, 0x01, 0x01, 0x01, 0x60, 0x00, 0x00, 0x03, 0x00, 0x90, 0x00, 0x00, 0x03, 0x00,
        0x00, 0x03, 0x00, 0x3C, 0xA0, 0x0A, 0x08, 0x0F, 0x16, 0x59, 0x59, 0xA4, 0x93, 0x2B,
        0xC0, 0x5A, 0x02, 0x00, 0x00, 0x03, 0x00, 0x02, 0x00, 0x00, 0x03, 0x00, 0x32, 0x10
    ])
    static let hevcPPS = Data([0x44, 0x01, 0xC1, 0x72, 0xB4, 0x62, 0x40])

    private func h264Decoder() -> VideoDecoder {
        let decoder = VideoDecoder()
        decoder.spsData = Self.h264SPS
        decoder.ppsData = Self.h264PPS
        return decoder
    }

    private func av1cAtom(_ format: CMFormatDescription?) -> [UInt8]? {
        guard let format,
              let atoms = CMFormatDescriptionGetExtension(
                format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms)
                as? [String: Data]
        else { return nil }
        return atoms["av1C"].map(Array.init)
    }

    // MARK: - H.264

    @Test func h264ParameterSetsDescribeTheirPicture() throws {
        let decoder = h264Decoder()
        #expect(decoder.rebuildH264FormatDescription())
        let format = try #require(decoder.formatDescription)
        #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_H264)
        let size = CMVideoFormatDescriptionGetDimensions(format)
        #expect(size.width == 320 && size.height == 240)

        var count = 0
        var headerLength: Int32 = 0
        var pointer: UnsafePointer<UInt8>?
        var length = 0
        #expect(CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: 1, parameterSetPointerOut: &pointer, parameterSetSizeOut: &length,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: &headerLength) == noErr)
        #expect(count == 2)
        #expect(headerLength == 4)
        let pps = try #require(pointer)
        #expect(Data(bytes: pps, count: length) == Self.h264PPS)
    }

    @Test func h264RebuildReplacesFormatAndDropsHDRCache() throws {
        let decoder = h264Decoder()
        #expect(decoder.rebuildH264FormatDescription())
        let first = try #require(decoder.formatDescription)
        decoder.cachedHDRFormatDescription = first
        #expect(decoder.rebuildH264FormatDescription())
        #expect(decoder.cachedHDRFormatDescription == nil)
        #expect(decoder.formatDescription.map { $0 !== first } == true)
    }

    @Test func h264NeedsBothParameterSets() {
        let decoder = VideoDecoder()
        decoder.spsData = Self.h264SPS
        #expect(!decoder.rebuildH264FormatDescription())
        decoder.spsData = nil
        decoder.ppsData = Self.h264PPS
        #expect(!decoder.rebuildH264FormatDescription())
        #expect(decoder.formatDescription == nil)
    }

    @Test func malformedH264ParameterSetKeepsThePreviousFormat() throws {
        let decoder = h264Decoder()
        #expect(decoder.rebuildH264FormatDescription())
        let good = try #require(decoder.formatDescription)
        decoder.spsData = Data([0x67, 0xFF])
        #expect(!decoder.rebuildH264FormatDescription())
        #expect(decoder.formatDescription === good)
    }

    // MARK: - HEVC

    @Test func hevcParameterSetsDescribeTheirPicture() throws {
        let decoder = VideoDecoder()
        decoder.vpsData = Self.hevcVPS
        decoder.spsData = Self.hevcSPS
        decoder.ppsData = Self.hevcPPS
        decoder.cachedHDRFormatDescription = nil
        #expect(decoder.rebuildHEVCFormatDescription())
        let format = try #require(decoder.formatDescription)
        #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_HEVC)
        let size = CMVideoFormatDescriptionGetDimensions(format)
        #expect(size.width == 320 && size.height == 240)

        var count = 0
        var headerLength: Int32 = 0
        var pointer: UnsafePointer<UInt8>?
        var length = 0
        #expect(CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
            format, parameterSetIndex: 0, parameterSetPointerOut: &pointer, parameterSetSizeOut: &length,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: &headerLength) == noErr)
        #expect(count == 3)
        #expect(headerLength == 4)
        let vps = try #require(pointer)
        #expect(Data(bytes: vps, count: length) == Self.hevcVPS)
    }

    @Test func hevcNeedsAllThreeParameterSets() {
        let decoder = VideoDecoder()
        decoder.spsData = Self.hevcSPS
        decoder.ppsData = Self.hevcPPS
        #expect(!decoder.rebuildHEVCFormatDescription())
        #expect(decoder.formatDescription == nil)
    }

    @Test func malformedHEVCParameterSetFails() {
        let decoder = VideoDecoder()
        decoder.vpsData = Self.hevcVPS
        decoder.spsData = Data([0x42, 0x01, 0xFF])
        decoder.ppsData = Self.hevcPPS
        #expect(!decoder.rebuildHEVCFormatDescription())
        #expect(decoder.formatDescription == nil)
    }

    // MARK: - AV1

    @Test func av1ConfigRecordCarriesTheParsedSequenceHeader() throws {
        let decoder = VideoDecoder()
        decoder.streamWidth = 1920
        decoder.streamHeight = 1080
        // Profile 1 (High), 10-bit, 4:4:4: high_bitdepth set, both subsampling bits clear.
        #expect(decoder.rebuildAV1FormatDescription(obuData: AV1SequenceHeaderTests.sequenceHeader(decoderModel: false)))
        let format = try #require(decoder.formatDescription)
        #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_AV1)
        let size = CMVideoFormatDescriptionGetDimensions(format)
        #expect(size.width == 1920 && size.height == 1080)
        #expect(av1cAtom(format) == [0x81, 0x20, 0x40, 0x00])
    }

    @Test func av1SequenceHeaderAfterTemporalDelimiterIsFound() {
        let decoder = VideoDecoder()
        decoder.streamWidth = 640
        decoder.streamHeight = 360
        let temporalDelimiter = Data([0x12, 0x00])
        let obus = temporalDelimiter + AV1SequenceHeaderTests.sequenceHeader(decoderModel: true)
        #expect(decoder.rebuildAV1FormatDescription(obuData: obus))
        #expect(av1cAtom(decoder.formatDescription) == [0x81, 0x20, 0x40, 0x00])
    }

    @Test func av1WithoutSequenceHeaderFallsBackToNegotiatedMain() {
        let decoder = VideoDecoder()
        decoder.streamWidth = 640
        decoder.streamHeight = 360
        let temporalDelimiter = Data([0x12, 0x00])
        // Main 4:2:0 8-bit: only the two subsampling bits.
        #expect(decoder.rebuildAV1FormatDescription(obuData: temporalDelimiter))
        #expect(av1cAtom(decoder.formatDescription) == [0x81, 0x00, 0x0C, 0x00])
        // A Main10 negotiation adds high_bitdepth.
        decoder.streamVideoFormat = StreamProtocol.VIDEO_FORMAT_AV1_MAIN10
        #expect(decoder.rebuildAV1FormatDescription(obuData: temporalDelimiter))
        #expect(av1cAtom(decoder.formatDescription) == [0x81, 0x00, 0x4C, 0x00])
    }

    @Test func emptyAV1PictureBuildsNothing() {
        let decoder = VideoDecoder()
        decoder.streamWidth = 640
        decoder.streamHeight = 360
        #expect(!decoder.rebuildAV1FormatDescription(obuData: Data()))
        #expect(decoder.formatDescription == nil)
    }

    // MARK: - Start codes

    @Test func stripStartCodeRemovesOnlyALeadingStartCode() {
        let decoder = VideoDecoder()
        #expect(decoder.stripStartCode(Data([0, 0, 0, 1, 0x67, 0x64])) == Data([0x67, 0x64]))
        #expect(decoder.stripStartCode(Data([0, 0, 1, 0x68, 0xEB])) == Data([0x68, 0xEB]))
        #expect(decoder.stripStartCode(Data([0, 0, 0, 1])).isEmpty)
        #expect(decoder.stripStartCode(Data([0x67, 0, 0, 1])) == Data([0x67, 0, 0, 1]))
        #expect(decoder.stripStartCode(Data([0, 0, 2, 0x67])) == Data([0, 0, 2, 0x67]))
        #expect(decoder.stripStartCode(Data([0, 0])) == Data([0, 0]))
    }

    @Test func strippedAnnexBParameterSetsBuildTheSameFormat() throws {
        let decoder = VideoDecoder()
        decoder.spsData = decoder.stripStartCode(Data([0, 0, 0, 1]) + Self.h264SPS)
        decoder.ppsData = decoder.stripStartCode(Data([0, 0, 1]) + Self.h264PPS)
        #expect(decoder.rebuildH264FormatDescription())
        let size = CMVideoFormatDescriptionGetDimensions(try #require(decoder.formatDescription))
        #expect(size.width == 320 && size.height == 240)
    }
    // MARK: - Sample buffers

    @Test func sampleBufferNeedsAFormatDescription() {
        #expect(VideoDecoder().makeSampleBuffer(rawData: Data([0, 0, 0, 1, 0x65])) == nil)
    }

    @Test func sampleBufferOwnsTheFrameBytesUnderTheCurrentFormat() throws {
        let decoder = h264Decoder()
        #expect(decoder.rebuildH264FormatDescription())
        let frame = decoder.convertAnnexBToAVCC(Data([0, 0, 0, 1, 0x65, 0x88, 0x84, 0x00, 0x2B]))
        let sample = try #require(decoder.makeSampleBuffer(rawData: frame, rtpTimestamp: 180_000))

        #expect(CMSampleBufferGetFormatDescription(sample) === decoder.formatDescription)
        #expect(CMSampleBufferGetNumSamples(sample) == 1)
        #expect(CMSampleBufferGetSampleSize(sample, at: 0) == frame.count)
        #expect(CMSampleBufferDataIsReady(sample))
        let block = try #require(CMSampleBufferGetDataBuffer(sample))
        var copied = [UInt8](repeating: 0, count: frame.count)
        #expect(CMBlockBufferCopyDataBytes(
            block, atOffset: 0, dataLength: frame.count, destination: &copied) == kCMBlockBufferNoErr)
        #expect(copied == [0, 0, 0, 5, 0x65, 0x88, 0x84, 0x00, 0x2B])
    }

    @Test func rtpTimestampBecomesA90kHzPresentationTime() throws {
        let decoder = h264Decoder()
        #expect(decoder.rebuildH264FormatDescription())
        let stamped = try #require(decoder.makeSampleBuffer(rawData: Data([0, 0, 0, 1, 0x65]), rtpTimestamp: 180_000))
        let pts = CMSampleBufferGetPresentationTimeStamp(stamped)
        #expect(pts.value == 180_000 && pts.timescale == 90_000)
        #expect(pts.seconds == 2)
        #expect(!CMSampleBufferGetDecodeTimeStamp(stamped).isValid)

        let unstamped = try #require(decoder.makeSampleBuffer(rawData: Data([0, 0, 0, 1, 0x65])))
        #expect(!CMSampleBufferGetPresentationTimeStamp(unstamped).isValid)
    }

    @Test func emptyFrameBuildsNoSample() {
        let decoder = h264Decoder()
        #expect(decoder.rebuildH264FormatDescription())
        #expect(decoder.makeSampleBuffer(rawData: Data(), rtpTimestamp: 90_000) == nil)
    }
}
