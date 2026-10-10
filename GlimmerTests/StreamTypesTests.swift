// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  StreamTypesTests.swift
//
//  The stream value types' wire encodings, overlay labels, codec ranking and error copy.
//

import Foundation
import Testing

@testable import Glimmer

struct StreamTypesTests {

    /// Limelight.h's STREAM_CFG_*, COLORSPACE_* and COLOR_RANGE_* values.
    @Test func configEnumsEncodeLimelightValues() {
        #expect([Remoteness.local, .remote, .auto].map(\.cValue) == [0, 1, 2])
        #expect([ColorSpace.rec601, .rec709, .rec2020].map(\.cValue) == [0, 1, 2])
        #expect([ColorRange.limited, .full].map(\.cValue) == [0, 1])
    }

    /// MAKE_AUDIO_CONFIGURATION(count, mask) = mask << 16 | count << 8 | 0xCA.
    @Test func audioConfigsPackChannelMaskAndCount() {
        #expect(AudioConfig.stereo.cValue == 0x0003_02CA)
        #expect(AudioConfig.surround51.cValue == 0x003F_06CA)
        #expect(AudioConfig.surround71.cValue == 0x063F_08CA)
        #expect([AudioConfig.stereo, .surround51, .surround71].map(\.channelCount) == [2, 6, 8])
    }

    @Test func audioConfigsReadAsTheirOverlayLabels() {
        #expect(AudioConfig.stereo.displayLabel == "Stereo")
        #expect(AudioConfig.surround51.displayLabel == "5.1 surround")
        #expect(AudioConfig.surround71.displayLabel == "7.1 surround")
    }

    @Test func topCodecPrefersAV1ThenHEVCOverAnyProfileBit() {
        #expect(VideoFormats.av1High10_444.topCodec == .av1)
        #expect(([.h264, .hevc, .av1Main10] as VideoFormats).topCodec == .av1)
        #expect(VideoFormats.hevcRext8_444.topCodec == .hevc)
        #expect(([.h264, .hevcMain10] as VideoFormats).topCodec == .hevc)
        #expect(VideoFormats.h264.topCodec == .h264)
        #expect(VideoFormats().topCodec == .h264)
    }

    /// 4:4:4 is advertised only on top of the codec's 4:2:0 profiles, and Main10 rides with HEVC.
    @Test func probedFormatsNeverClaimAProfileWithoutItsBase() {
        let probed = VideoFormats.probedSupported
        #expect(probed.contains(.hevc) == probed.contains(.hevcMain10))
        #expect(probed.contains(.av1) == probed.contains(.av1Main10))
        if !probed.isDisjoint(with: [.hevcRext8_444, .hevcRext10_444]) { #expect(probed.contains(.hevc)) }
        if !probed.isDisjoint(with: [.av1High8_444, .av1High10_444]) { #expect(probed.contains(.av1)) }
        #expect(probed.isDisjoint(with: .h264YUV444))
    }

    @Test func streamErrorsReadAsSentences() {
        let cases: [(StreamError, String)] = [
            (.binaryNotFound, "Streaming library not available."),
            (.hostUnreachable("timed out"), "Couldn't reach the PC: timed out."),
            (.pairingFailed("bad PIN"), "Pairing failed: bad PIN"),
            (.pairingRejected, "Pairing failed. Try again."),
            (.launchFailed("busy"), "Couldn't launch app: busy"),
            (.sessionFailed(-1), "Streaming session ended (code -1)."),
            (.decoderFailed("no session"), "Video decoder failed: no session"),
            (.audioFailed("no device"), "Audio failed: no device"),
            (.crypto("bad key"), "Cryptography error: bad key"),
            (.truncatedRead("eof"), "Control connection ended early: eof"),
            (.streamPortsBlocked(proto: "UDP", port: 47998), "The stream couldn't get through on UDP 47998."),
            (.hostTimedOut, "The PC didn't respond in time."),
            (.hostRefused(message: "App not found", code: 404), "App not found (code 404)"),
            (.hostCertChanged("Pair Den again."), "Pair Den again."),
            (.sunshineNeedsRestart("Restart Sunshine."), "Restart Sunshine."),
            (.gameStreamHost, "Glimmer needs Sunshine on the PC, which is running NVIDIA GameStream.")
        ]
        for (error, sentence) in cases {
            #expect(error.description == sentence)
        }
    }

    /// Bridged through NSError, the sentence must survive rather than "StreamError error 0".
    @Test func localizedDescriptionIsTheSentence() {
        let error: Error = StreamError.hostTimedOut
        #expect(error.localizedDescription == "The PC didn't respond in time.")
        #expect((error as NSError).localizedDescription == "The PC didn't respond in time.")
    }
}
