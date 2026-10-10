// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// Real 5 ms CELT packets at Sunshine's settings, with a distinct -12 dBFS tone per channel.
// Silence, a stall, wrong channel order or a dead channel all change the decoded samples.

import Foundation
import Testing
@testable import Glimmer

struct OpusDecoderTests {

    private static let stereo = [
        "ec7f4bd60777985d8731b747622a18fd2b679a2e9def04904278899d9136b906038d671fa4e046bc58abc93cb740be2bcd584efccd910bf0cff90084",
        "ecc8b89010be17d51a2b34d6852b3ac4d7c33ace08a21eff5aae3eacff7a34b6cea490b94b28ab226da7e91382d7128dc6f75c34000febc11f8a4b13",
        "ecc85e2a7260a98bd240544742674e73cd84b9044ca02a89b1192dcead05793df85afd62dd245bb923c409023199c4d690ba5136aaff474cc44d5312",
        "ecc8a90053eb7363cf9cb521719ab8d1788db26fb0e031265ccd726e45328df4bc90fe98addf0cedd7194fbba2b8b569425c90fb53d0b5d2514d0712",
        "ecc839e66ceabdc6e046c54aca71bbc4d5f381392fdbfc66cb1c45609162df8849385700a2c44561eb939851a40b578a91696969e9450b0fcddf6b12"
    ]

    private static let surround = [
        "ec317f4bd60777985d8731b747622a18fd2b58ba3e0057468ddd3732e3f92382a6590cbf5f174f9d47c1e3c1d28d842fffd044ec319fd4b5"
            + "93502f5b1414326a43ad3e59c5422a6f2bea5105ec8cc5544ec719abb94bb2d30ddf292990900ba68c52530d0a91e81d7e0124724f22854c"
            + "88e49d2652e2dd3f2905585239a73db649004c23bde87e4f6593f28af9160db0a92afd9a568435086428a6e3a40f0f83",
        "ec31c8b89010be17d51a2b345fed2a1849e43875866d8fb917594ca8a0ace631286e75e985afc9ec18be34570d002bc1e2d713ec319e7285"
            + "495c88266495ac16fd2d44a316ee271d1b0e697eeb7c01a383e3d86ef95865976771aaaac95aaeab40088cc333d2e81d9e6b2cbacda0a0fd"
            + "f4e83f340a14f69698e19f055f0e761df7003cc3e5e8880cff26d2f6e53c7e90a770af0588dd10a874108a8f402a007e",
        "ec31c85e2a7260a9956dc90ff5e330f05360127d4f9d338f20e7b07b9817c948a48213ee866361ffeee8aea416fd1f45139b12ec319e8327"
            + "c8fd131222e03e73f4522a871364d2f740bd0394b1311b57fea3f3c20fb702a05aaed7ac85c6ef16668fe70dd2d1e81d9d5ad8feccb55d64"
            + "46c2d07415dd37266a881cf26da17b5b760077b1e5e887cbc3fab1cc590788c64ae37f3fde3e7c06b5d0c86d404308fe"
    ]

    private static let surroundLong = [
        "ec377f4bd21d2ee5d6ecdaea490e93972351a8182b6c6ddc47aac570019b1d51b4c5a9005ca232cd5ec93cb740beba7d3127"
            + "c3fcf0023b24cbec37b52a08ddb39b22b9215814b50034a67fa788dd22db3e9b50d967f022e56c0149099c22692edd7927d4"
            + "f17853a15b5bb661e0666d327309e8217e15890da5bea73245d9c2ad72d731712991728ddd4a9ae39d3a3783cf4e83b407e8"
            + "7e1575bfb15cfd2db6842a410171f8e8da692c998b809eb647c0790f2406",
        "ec37c876c6082895893c60abdb3bedc2c02de7204d9b06313f7ac6762af3eaa1b36e66fc183a8073508b8a2d3ca571289700"
            + "001d56b72b36baec37b38c8b54c3c3eb4a2067479874b2626301fa315057858f473c683c6d4cc1f97149fecc112f06912872"
            + "d3ecc2afb333600006985aaf318ae8219d5805299036ee627e06acbc2c0cc7897a6b425f7c2b97293924072270005d60f6e8"
            + "9e5071bf5af84331c48a75fb819691a088fffdf897d01f0d060a003ca8ed",
        "ec37de0de729406e8754b83ba2b19964a57a6f43854063069b5518152871f202be1a272111c6831977248b59f8d74e037cc7"
            + "f1d7d8dec95ddaec37b38c935df0bfab30dc64cd291afb9cad0e3b5662cacbc2f8ef194b8f0fdb11115215e244f45aafe369"
            + "b89450d259cef69f5aa559ca718ae8219c5aaf1cd8b5cdcb392526440135444493160283d84b5a3aca9b822ef00f75b2f6e8"
            + "9c4e19dd75932cf76b754eca5b9bb050520399f536793304d792006bb1ed",
        "ec37ddacaf105009d13ebd7531ac70fcdc5811d71cd5f3de231865c9618c6dd84d62c20fa275d61a48e722eba225d126b49d"
            + "6df91db7cc9ee1ec37de37b45d33c3113602fbd625c095ff98b11a8481c34430d3a0d83ca94e28509766b0e77bff38c30fde"
            + "a5abc75fb965127fc06472a4f6e1e8219e8155c9ce92edd8d0797d49c9acec4999d29e813d501b68ef672ff459f3f82af6e8"
            + "9e95cd98673baa926817dd79e3888888cbce87f32681c2098ddcbfffa9ed",
        "ec37dd8a7fb9dbecbb76fa97a3173352d6d17ddfbfd03cc8ead776ce65bc876b32aff3043ed0a74524ce3c336cc4dad55ca1"
            + "fd35fe884beee1ec37dc030284fedc86220ea0e81e21dec683965a82ee486cb56ee06d5722f73ea7300feb0f580895ed3d8b"
            + "f00fc9b81be2baac1ca229a83ee1e8219e8155c9ce92edd8d078fd1e4e29c524b5fe96f10ca1574006a6f22ef1f3f82ef6e8"
            + "9e7e0f7397f75056d38056caf012f5dd533bcb2aaac512224d65bfffb1ed"
    ]

    private static let surroundHigh = [
        "e81d7f5ab49456e9bfb641b7972ea27d664267394f132ecbbad9240160ca43e81d7b080aa0b557b922f1b8f32ce174d0c794"
            + "51041ab3c12b64900122bba6e81d7ae0b4646e8a5c1cf2abe630a43bc8049c3a885a0a8c5ad92400b17bc4e81d7e15890da5"
            + "bea7325432ed3d43dd477c588473174776cb649001e0da07e81d7e1575bfb15cfd2db8a1c69a904dc6805886810d6fe99ad9"
            + "24010f2406e87e0124724f22854c826fd57ca3de6d36b5404e9caa04c4cd",
        "e81dc321a1b7aab6841ef63c562f209583f696abc12f86c1ca1468001e6ba1e81db149c6e049990409d3e26b60fd96ef62fa"
            + "0b5dd613c80e44800066e1e1e81db347d83acb5c567197e06917b97343924796c5209ec9912ff80007ebc6e81d9d5805298f"
            + "9af08b3a71ab8f4e5cd4b71769163961b593f2260016b0f6e81d9e5071bf5af84331cb4b9ad92d60e5d49af01191b7a1acd0"
            + "46003ca8ede89d60884df753b927b0a9030c9d9f70b2ad471f44880e00e6",
        "e81dc6a1fbd97f9475fe8d669da56883dbb751735e5edb29423a9803d2e7a1e81daedaf0ee3e94b353b15ff291315d87418c"
            + "9d883418cf7913e8013c5de1e81db13cb832013775e27940d970a309e692484361150cca1ad3c00028a1c6e81d9c5aaf1d0c"
            + "7127f7dfcf36fba3fab377a56e6ee3ad94eac8a0017ad9f6e81d9c4e19dd7590e43f4e74cf1279cfec14e3b63b5fd0a282b5"
            + "e50035b1ede89d24e770cd2a1e60395ff4c40603942afd6be983081163e6",
        "e81dc86a5b8f0ac74ba0fd7e927d169a85f7c6dba9602083a552be320ddfa1e81db354044bd625cd3d57aa79c5bc977cd8c3"
            + "5f438745fa7d7ffd0e3f79e1e81db3c7057d4b96a00b7968622d03aaac5803880a6dd6a63cba70c73b25c6e81d9bdb16adc0"
            + "4c78157981cd8f53dbf0493adfab85f18b72519327bb76f6e81d9e95cd98673baa926817da4537a00bb0243b175dbfa65a85"
            + "dcbffea9ede89c031aa13539513d48331e91a2e5dd90037c51e671575ee6",
        "e81dc86a5b8f0adb4f2c55eb435ac1f92ae00f1503cd7f0115083e360ddfa1e81db354044bd62657067dae7fb4bd64963801"
            + "d60d01ba7cfd91111c3f7be1e81db3ac071365b580f7de980d2654eeb1f57f29155d008d334710c73b29c6e81d9e8155c9ce"
            + "92edd8c7739be3cd3261d4fdb060bd7abe802610bcfe17f6e81d9e7e0f7397f75056d38056caf8f4fd2ed115d588789dd6cd"
            + "65bffeb1ede8997f630546f2595b3d2e29bec72083db7e33e90af9c2d9e6"
    ]

    private static let sevenPointOne = [
        "ec387f4bd21d2ee5d6ecdaea490e93a8979bee3246f2e47ee3561a5bee35fd1b9f9e7c1b8f3b46af6313966d62e8579ab094"
            + "e667ef0038ec94cbec38b52a08ddb39b22b9215814b50034a67f9c8725f541d3a3598bb2ff7284fb552cfe04fdd1cdb7c749"
            + "3eba05f0a742b2db9661e0666d327309ec387e013918542537e758abbb98d6b79af66de539114f11e0667b8d86db4e4917b1"
            + "628d7a67d49b104d774ea78bd742bc488be54aa96144005be822707589a0764c7fadab156449d6b6c8f24468c0b1ca3163c1"
            + "78e74e8de0f3ec6c4e6ce87e4f6593f28af91612d9d58b8059e308df77ce3b81b4557b248074ed03",
        "ec38c876c6082895893c60abdb3bedc2c2c1eb6e5267937c7a4035eefeb743e58e5cfa86e02b94809d714918d9ef29012897"
            + "00001d56b72b36baec38b38c8b54c3c3eb4a2067479874b2626301fa315057858ee34162d4461843df01a8ef9eda7ab0e31a"
            + "fd7d1b8bbbc9999a000006985aaf318aec38c91c00e91ed7ca1080ea0756a3b5c82c26a2007fba043c194bb709c005939f02"
            + "223742ebb0f59b65fee06eb0539230ea70029bd431efd358e8229e6c54b890e17f99d60d2a0faf06f11e03acb05f56efa166"
            + "2c8b71e0318001c700e1e888fd02e4669fa0f7883f6367a5e9bbc4d5e77b54bc6485c75c000b207d",
        "ec38de0de729406e8754b83ba2b19964ab808affcc88cb550b75a3046fc4f80872702dc7e87b62a82773fb697e2f9898742c"
            + "7f1d7d8e7b2575daec38b38c935df0bfab30dc64cd291afb9cad0e3b566447b49b58778d74c6e8b0c805171528abb81ad894"
            + "c190c7ae7931333ed275aa5587aa718aec389e5a1be03f746c0814ed6a1fdc0ea6d17da2a746220294dc745b08e57748990b"
            + "6d9836a6b9b2f73c247d73e8987fc3fe101b5bbb711d6bcee8229c49963fd75588d1d195b5d887afd9ae7d4b000472c0efa6"
            + "52b49e56be201d0c5be1e887d16685208d31311221617553d5dda7e956ff203f7e22aca800ebf07d",
        "ec38ddacaf105009d13ebd7531ac70fcdc5811b9af5ed467d3677630b4d95836f374e77dac8a1332d33c0553af7a41161ad3"
            + "9d6df91d37cc9ee1ec38de37b45d33c3113602fbd625c095ff98b11a8481c34430c08993ab3286a18eebc7f0229d826653fe"
            + "5bfa1b00a7ae0f2c09ff106472a4f6e1ec389e72d4214173b73fcdc161f9f9f5d016c39d9f02bd6da05f93cf7d9c8747552f"
            + "caba46c9567bbc2a58276c3edc46a46c83b412928527456ee8229d09d5926876c8fddcdf547b9d584c47542c680ea36d69ac"
            + "3681614214d9ec61b4e1e8868b2266bf9c46f2b0d360ab58bfd1f5969f1686774a6899094bed9b7d",
        "ec38dd8a7fb9dbecbb76fa97a3173352d6d17e0aba84d36087bba4fd672399004b0fa20d928eac37c4d81633607a2d6b5572"
            + "87f4d7fa284beee1ec38dc030284fedc28c98ae3b69f692adee30761531d9f0c3dfe4beb28c23253ff32e5912e69d9718c70"
            + "a6a8e005f01880aeab1978a229a83ee1ec3897b411d361b1764472c024d16d8f0687db1306e4f1399af60110658e6a2538ee"
            + "6f795a5d0247267c42900352a78322b0bd12ff144d74e26ee822966b67a3a6717c8496baaaf72a2a88f8f13d8f42cad780ba"
            + "3282d456be2cf784a9e1e8846e9047286ff3cc8cd70415a44d87164df068e8a4fcfd88041beecefd"
    ]

    private static let sevenPointOneHigh = [
        "e81d7f5ab49456e9bfb641b7972ea27d664267394f132ecbbad9240160ca43e81d7b080aa0b557b922f1b8f32ce174d0c794"
            + "51041ab3c12b64900122bba6e81d7ae0b4646e8a5c1cf2abe630a43bc8049c3a885a0a8c5ad92400b17bc4e81d7e15890da5"
            + "bea7325432ed3d43dd477c588473174776cb649001e0da07e81d7e1575bfb15cfd2db8a1c69a904dc6805886810d6fe99ad9"
            + "24010f2406e81d7e0124724f22854c88e49e935e90f0112905585239a73db649004c233de81d707589a0764c7fadab1d4374"
            + "69ecc5bc1172c24eaadc84b6c90096272ce87e4f6593f28af9160da47e4497a409843c44bc831cc1",
        "e81dc321a1b7aab6841ef63c562f209583f696abc12f86c1ca1468001e6ba1e81db149c6e049990409d3e26b60fd96ef62fa"
            + "0b5dd613c80e44800066e1e1e81db347d83acb5c567197e06917b97343924796c5209ec9912ff80007ebc6e81d9d5805298f"
            + "9af08b3a71ab8f4e5cd4b71769163961b593f2260016b0f6e81d9e5071bf5af84331cb4b9ad92d60e5d49af01191b7a1acd0"
            + "46003ca8ede81d9e4ec5bf3db8447a2649cf9c853556e605c195d52a3d044fe1001f00e6e81d9e4f5e0df7836153b2fc4cd2"
            + "09358533f5bcbe1ed4f6fa02020039c0e1e887d01becdedee582fceefa0aa1161da14a83a90f007d",
        "e81dc6a1fbd97f9475fe8d669da56883dbb751735e5edb29423a9803d2e7a1e81daedaf0ee3e94b353b15ff291315d87418c"
            + "9d883418cf7913e8013c5de1e81db13cb832013775e27940d970a309e692484361150cca1ad3c00028a1c6e81d9c5aaf1d0c"
            + "7127f7dfcf36fba3fab377a56e6ee3ad94eac8a0017ad9f6e81d9c4e19dd7590e43f4e74cf1279cfec14e3b63b5fd0a282b5"
            + "e50035b1ede81d9d26919f8d4fd0718223416d1a8b7300ee062b12564f3ed15000626ae6e81d9d24e10bd277d64cc1edf82c"
            + "bc3cd47cb392f2a99feba2b5e40012eae1e8880cfec09a6fc5c1501c13763037ea372aac2c14d97d",
        "e81dc86a5b8f0ac74ba0fd7e927d169a85f7c6dba9602083a552be320ddfa1e81db354044bd625cd3d57aa79c5bc977cd8c3"
            + "5f438745fa7d7ffd0e3f79e1e81db3c7057d4b96a00b7968622d03aaac5803880a6dd6a63cba70c73b25c6e81d9bdb16adc0"
            + "4c78157981cd8f53dbf0493adfab85f18b72519327bb76f6e81d9e95cd98673baa926817da4537a00bb0243b175dbfa65a85"
            + "dcbffea9ede81d9bd35aee507f4e83d02cf3f85c7e45fc552e171d05735e223358f847e6e81d9d09d5b0c23b7023157fc24e"
            + "d5e3a486f0f3b555090c2511dd3afcdae1e886afa47d8cbfeeca26f523fd480e43ae20fcd645277d",
        "e81dc86a5b8f0adb4f2c55eb435ac1f92ae00f1503cd7f0115083e360ddfa1e81db354044bd62657067dae7fb4bd64963801"
            + "d60d01ba7cfd91111c3f7be1e81db3ac071365b580f7de980d2654eeb1f57f29155d008d334710c73b29c6e81d9e8155c9ce"
            + "92edd8c7739be3cd3261d4fdb060bd7abe802610bcfe17f6e81d9e7e0f7397f75056d38056caf8f4fd2ed115d588789dd6cd"
            + "65bffeb1ede81d997f5bc0f35b983dd77793bf496f0e973a5889f38183d43f2817eed9e6e81d966b67a3a6717c8496baab0a"
            + "574bfe56cf6d9c2454e277aef91df114e1e8846e903b6a4a6e6bc4d34468ee75345de61eac24b6fd"
    ]

    /// Sunshine's layouts, from its DESCRIBE surround-params once SdpScan has reordered them.
    private struct Layout {
        let channels: Int, streams: Int, coupled: Int, mapping: [UInt8]
        let packets: [String]
    }

    private static let layouts = [
        Layout(channels: 2, streams: 1, coupled: 1, mapping: [0, 1], packets: stereo),
        Layout(channels: 6, streams: 4, coupled: 2, mapping: [0, 1, 2, 4, 5, 3], packets: surroundLong),
        Layout(channels: 6, streams: 6, coupled: 0, mapping: [0, 1, 2, 3, 4, 5], packets: surroundHigh),
        Layout(channels: 8, streams: 5, coupled: 3, mapping: [0, 1, 2, 4, 5, 3, 6, 7], packets: sevenPointOne),
        Layout(channels: 8, streams: 8, coupled: 0, mapping: [0, 1, 2, 3, 4, 5, 6, 7], packets: sevenPointOneHigh)
    ]

    private static func decoder(channels: Int = 2, streams: Int = 1, coupled: Int = 1,
                                mapping: [UInt8] = [0, 1]) -> OpusDecoder? {
        OpusDecoder(sampleRate: 48_000, channels: channels, streams: streams, coupledStreams: coupled,
                    mapping: mapping, samplesPerFrame: 240)
    }

    /// Each packet's frames out and per-channel RMS through the playback path; nil packets are losses.
    private static func run(_ decoder: OpusDecoder, _ hex: [String?]) -> [(frames: Int, rms: [Float])] {
        var pcm = [Float](repeating: 0, count: 240 * decoder.channels)
        return hex.map { hex in
            let frames = pcm.withUnsafeMutableBufferPointer { out -> Int in
                guard let base = out.baseAddress else { return 0 }
                guard let hex, let packet = Data(hex: hex) else { return decoder.decodeOrConceal(nil, into: base) }
                return packet.withUnsafeBytes { decoder.decodeOrConceal($0, into: base) }
            }
            let rms = (0..<decoder.channels).map { channel -> Float in
                guard frames > 0 else { return 0 }
                let samples = (0..<frames).map { pcm[$0 * decoder.channels + channel] }
                return (samples.reduce(0) { $0 + $1 * $1 } / Float(frames)).squareRoot()
            }
            return (frames, rms)
        }
    }

    private static func pcm(_ decoder: OpusDecoder, packet: Data?) -> [Float] {
        var samples = [Float](repeating: 0, count: decoder.samplesPerFrame * decoder.channels)
        let frames = samples.withUnsafeMutableBufferPointer { out -> Int in
            guard let base = out.baseAddress else { return 0 }
            if let packet { return packet.withUnsafeBytes { decoder.decode($0, into: base) } }
            return decoder.decode(nil, into: base)
        }
        return Array(samples.prefix(frames * decoder.channels))
    }

    @Test(arguments: 0..<5)
    func everyLayoutDecodesAllChannels(index: Int) throws {
        let layout = Self.layouts[index]
        let decoder = try #require(Self.decoder(channels: layout.channels, streams: layout.streams,
                                               coupled: layout.coupled, mapping: layout.mapping))
        let out = Self.run(decoder, layout.packets)
        #expect(out.map(\.frames) == [120, 240, 240, 240, 240])
        for packet in out.dropFirst(2) { #expect(packet.rms.allSatisfy { $0 > 0.1 }, "\(packet.rms)") }
    }

    @Test func refusesLayoutsOpusCannotDescribe() {
        #expect(OpusDecoder(sampleRate: 0, channels: 2, streams: 1, coupledStreams: 1, mapping: [0, 1],
                            samplesPerFrame: 240) == nil)
        #expect(Self.decoder(channels: 2, mapping: [0]) == nil)
        #expect(Self.decoder(streams: 0, coupled: 0) == nil)
        #expect(Self.decoder(streams: 1, coupled: 2) == nil)
        #expect(Self.decoder(channels: 9, streams: 9, coupled: 0, mapping: Array(0..<9)) == nil)
    }

    /// A zero-byte packet would end the stream and fade it out; the in-band lost packet conceals and recovers.
    @Test func lostPacketIsConcealedAndTheStreamRecovers() throws {
        let decoder = try #require(Self.decoder())
        let out = Self.run(decoder, [Self.stereo[0], Self.stereo[1], Self.stereo[2], nil, Self.stereo[3], Self.stereo[4]])
        #expect(out.map(\.frames) == [120, 240, 240, 240, 240, 240])
        #expect(out[3].rms.allSatisfy { $0 > 0.05 }, "concealed \(out[3].rms)")
        for packet in out.suffix(2) { #expect(packet.rms.allSatisfy { $0 > 0.1 }, "recovered \(packet.rms)") }
    }

    /// A packet that won't decode used to schedule nothing, a 5 ms hole the meter read as an under-run.
    @Test func undecodablePacketIsConcealedAndTheStreamRecovers() throws {
        let decoder = try #require(Self.decoder())
        let malformed = "ed01"   // two equal frames can't share one byte
        let out = Self.run(decoder, [Self.stereo[0], Self.stereo[1], Self.stereo[2], malformed,
                                     Self.stereo[3], Self.stereo[4]])
        #expect(out.map(\.frames) == [120, 240, 240, 240, 240, 240])
        #expect(out[3].rms.allSatisfy { $0 > 0.05 }, "concealed \(out[3].rms)")
        for packet in out.suffix(2) { #expect(packet.rms.allSatisfy { $0 > 0.1 }, "recovered \(packet.rms)") }
    }

    @Test func lossBeforeAnyPacketYieldsNothing() throws {
        let decoder = try #require(Self.decoder())
        #expect(Self.run(decoder, [nil]).map(\.frames) == [0])
    }

    @Test(arguments: 1..<5)
    func surroundConcealsMissingPacketAndRecovers(index: Int) throws {
        let layout = Self.layouts[index]
        let decoder = try #require(Self.decoder(channels: layout.channels, streams: layout.streams,
                                               coupled: layout.coupled, mapping: layout.mapping))
        let out = Self.run(decoder, [layout.packets[0], layout.packets[1], nil,
                                    layout.packets[3], layout.packets[4]])
        #expect(out.map(\.frames) == [120, 240, 240, 240, 240])
        #expect(out[2].rms.allSatisfy { $0 > 0.05 }, "concealed \(out[2].rms)")
        for packet in out.suffix(2) { #expect(packet.rms.allSatisfy { $0 > 0.1 }, "recovered \(packet.rms)") }
    }

    @Test(arguments: [false, true])
    func surroundMappingPreservesAllSamples(muted: Bool) throws {
        let mapping: [UInt8] = muted ? [1, 0, 255, 0, 5, 4] : [5, 4, 3, 2, 1, 0]
        let reference = try #require(Self.decoder(channels: 6, streams: 4, coupled: 2, mapping: Array(0..<6)))
        let reordered = try #require(Self.decoder(channels: 6, streams: 4, coupled: 2, mapping: mapping))
        for hex in Self.surround {
            let packet = try #require(Data(hex: hex))
            let original = Self.pcm(reference, packet: packet)
            let actual = Self.pcm(reordered, packet: packet)
            #expect(actual.count == original.count)
            for sample in actual.indices {
                let channel = mapping[sample % 6]
                let expected = channel == 255 ? 0 : original[(sample / 6) * 6 + Int(channel)]
                #expect(actual[sample] == expected)
            }
        }
    }

    @Test func malformedTailDoesNotAdvanceEarlierStreams() throws {
        let reference = try #require(Self.decoder(channels: 6, streams: 4, coupled: 2, mapping: Array(0..<6)))
        let recovering = try #require(Self.decoder(channels: 6, streams: 4, coupled: 2, mapping: Array(0..<6)))
        let first = try #require(Data(hex: Self.surround[0]))
        #expect(Self.pcm(recovering, packet: first) == Self.pcm(reference, packet: first))
        let next = try #require(Data(hex: Self.surround[1]))
        let tail = try next.withUnsafeBytes { bytes -> Int in
            var start = 0
            for _ in 0..<3 {
                start = try #require(OpusPacket.parse(bytes, at: start, selfDelimited: true)).end
            }
            return start
        }
        #expect(Self.pcm(recovering, packet: Data(next.prefix(tail))).isEmpty)
        #expect(Self.pcm(recovering, packet: next) == Self.pcm(reference, packet: next))
        let last = try #require(Data(hex: Self.surround[2]))
        #expect(Self.pcm(recovering, packet: last) == Self.pcm(reference, packet: last))
    }
}

struct OpusPacketTests {
    @Test func selfDelimitedStreamsKeepTheirExactBoundaries() throws {
        let cases: [([UInt8], Range<Int>, Int)] = [
            ([0xEC, 2, 11, 12], 1..<2, 240),
            ([0xED, 2, 11, 12, 13, 14], 1..<2, 480),
            ([0xEE, 1, 2, 11, 12, 13], 2..<3, 480),
            ([0xEF, 2, 2, 11, 12, 13, 14], 2..<3, 480),
            ([0xEF, 0x82, 1, 2, 11, 12, 13], 3..<4, 480),
            ([0xEF, 0xC2, 3, 1, 2, 11, 12, 13, 0, 0, 0], 4..<5, 480),
            ([0xEC, 252, 0] + Array(repeating: 1, count: 252), 1..<3, 240),
            ([0xEF, 0x42, 255, 2, 1, 11, 12] + Array(repeating: 0, count: 256), 4..<5, 480),
            ([0xEC, 0], 1..<2, 240)
        ]
        for (packet, length, samples) in cases {
            let joined = [UInt8(0), 0] + packet + [0xEC, 1, 17]
            let parsed = try joined.withUnsafeBytes {
                try #require(OpusPacket.parse($0, at: 2, selfDelimited: true))
            }
            #expect(parsed.end == 2 + packet.count)
            #expect(parsed.lengthField == (length.lowerBound + 2)..<(length.upperBound + 2))
            #expect(parsed.samplesAt48kHz == samples)
        }
    }

    @Test func malformedFramingIsRejectedBeforeReadingPayload() {
        let packets: [[UInt8]] = [
            [], [0xEC], [0xEC, 252], [0xEC, 3, 11, 12], [0xED, 2, 11, 12, 13],
            [0xEE, 3, 1, 11, 12], [0xEF], [0xEF, 0, 0], [0xEF, 49, 0],
            [0xEF, 0x41, 255], [0xEF, 0xC2, 3, 1, 2, 11, 12, 13], [0xFF, 7, 0]
        ]
        for packet in packets {
            #expect(packet.withUnsafeBytes { OpusPacket.parse($0, at: 0, selfDelimited: true) } == nil)
        }
        let invalidLast: [[UInt8]] = [[0xED, 1], [0xEE, 3, 1, 2], [0xEF, 2, 1, 2, 3],
                                      [0xEC] + Array(repeating: 0, count: 1_276)]
        for packet in invalidLast {
            #expect(packet.withUnsafeBytes { OpusPacket.parse($0, at: 0, selfDelimited: false) } == nil)
        }
    }
}
