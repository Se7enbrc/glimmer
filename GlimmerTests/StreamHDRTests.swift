// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  StreamHDRTests.swift
//
//  What this Mac offers the PC: HDR off takes out every 10-bit format (so the PC
//  encodes SDR), a PC's codec choice takes out whole codec families, and the spec
//  tag promises HDR only on a display that can show it.
//

import GlimmerEngine
import Testing
@testable import Glimmer

struct StreamHDRTests {
    private let settings = IsolatedDefaults()

    private let probed: VideoFormats = [.h264, .hevc, .hevcMain10, .hevcRext8_444, .hevcRext10_444,
                                        .av1, .av1Main10, .av1High8_444, .av1High10_444]

    @MainActor @Test func launcherUsesRec709FullRegardlessOfTheHDROffer() {
        let model = AppModel(defaults: settings.defaults)
        let pc = Host(id: "colour-pc", name: "PC", customName: nil, localAddress: "192.0.2.10",
                      manualAddress: nil, apps: [], lastConnected: nil, serverCertPEM: nil,
                      appVersion: nil, macAddress: nil)
        let config = model.nativeStreamConfig(for: pc)
        #expect(config.colorSpace == .rec709 && config.colorRange == .full)
        for hdr in [false, true] {
            var request = config
            request.videoFormats = AppModel.videoFormats(probed, hdr: hdr)
            #expect((request.colorSpace.cValue << 1) | request.colorRange.cValue == 3)
            #expect(request.videoFormats.contains(.hevcMain10) == hdr)
        }
    }

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

    @Test func hevcPreferenceRemovesEveryAV1Profile() {
        let offered = HostCodecPreference.hevc.apply(to: probed)
        #expect(offered == [.h264, .hevc, .hevcMain10, .hevcRext8_444, .hevcRext10_444])
        #expect(offered.topCodec == .hevc)
        #expect(AppModel.videoFormats(offered, hdr: false) == [.h264, .hevc, .hevcRext8_444])
    }

    @Test func h264PreferenceRemovesEveryHEVCAndAV1Profile() {
        let offered = HostCodecPreference.h264.apply(to: probed)
        #expect(offered == [.h264])
        #expect(AppModel.videoFormats(offered, hdr: false) == [.h264])
    }

    @Test func automaticPreferenceKeepsEveryProbedFormat() {
        #expect(HostCodecPreference.auto.apply(to: probed) == probed)
    }

    @Test func tagNeedsHDROnAndAnHDRDisplay() {
        #expect(AppModel.showsHDR(requested: true, edrHeadroom: 16))
        #expect(!AppModel.showsHDR(requested: true, edrHeadroom: 1))
        #expect(!AppModel.showsHDR(requested: true, edrHeadroom: nil))
        #expect(!AppModel.showsHDR(requested: false, edrHeadroom: 16))
    }
}
