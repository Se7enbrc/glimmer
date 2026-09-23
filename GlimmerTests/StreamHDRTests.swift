//
//  StreamHDRTests.swift
//
//  The HDR choice: off takes every 10-bit format out of the offer (so the PC
//  encodes SDR), and the spec tag promises HDR only on a display that can show it.
//

import Testing
@testable import Glimmer

struct StreamHDRTests {

    private let probed: VideoFormats = [.h264, .hevc, .hevcMain10, .hevcRext8_444, .hevcRext10_444,
                                        .av1, .av1Main10, .av1High8_444, .av1High10_444]

    @Test func hdrOnOffersEverythingProbed() {
        #expect(AppModel.videoFormats(probed, hdr: true) == probed)
    }

    @Test func hdrOffOffersNo10BitFormat() {
        let offered = AppModel.videoFormats(probed, hdr: false)
        #expect(offered == [.h264, .hevc, .hevcRext8_444, .av1, .av1High8_444])
        #expect(offered.isDisjoint(with: [.hevcMain10, .av1Main10]))
    }

    @Test func hdrOffKeepsTheCodecAndItsBitrateDiscount() {
        #expect(AppModel.videoFormats(probed, hdr: false).topCodec == .av1)
        #expect(AppModel.videoFormats([.h264, .hevc, .hevcMain10], hdr: false).topCodec == .hevc)
    }

    @Test func tagNeedsHDROnAndAnHDRDisplay() {
        #expect(AppModel.showsHDR(requested: true, edrHeadroom: 16))
        #expect(!AppModel.showsHDR(requested: true, edrHeadroom: 1))
        #expect(!AppModel.showsHDR(requested: true, edrHeadroom: nil))
        #expect(!AppModel.showsHDR(requested: false, edrHeadroom: 16))
    }
}
