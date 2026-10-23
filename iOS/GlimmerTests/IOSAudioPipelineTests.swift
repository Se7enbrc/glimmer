// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AVFAudio
import AudioToolbox
import CommonCrypto
import Foundation
import Testing
@testable import Glimmer
@testable import GlimmerEngine

extension IOSAudioOutputTests {
    // The same synthetic 5 ms stereo CELT tone used by the shared decoder tests.
    private static let tone = "ec7f4bd60777985d8731b747622a18fd2b679a2e9def04904278899d9136b906038d671fa4e046bc58"
        + "abc93cb740be2bcd584efccd910bf0cff90084"
    private static let key = Array(UInt8(0)..<UInt8(16))

    @Test(arguments: [44_100.0, 48_000.0], [UInt32(1), 2])
    func encryptedRTPReachesNativeMixerAsNonSilentPCM(outputRate: Double, outputChannels: UInt32) throws {
        // Pull the real processing units synchronously; RemoteIO never starts a hardware render thread.
        let session = IOSAudioSession(notifications: NotificationCenter())
        var calls = IOSAudioOutput.Calls()
        let create = calls.create
        let get = calls.get
        var mixer: AudioUnit?
        calls.create = { description in
            let unit = try create(description)
            if description.componentSubType == kAudioUnitSubType_MultiChannelMixer { mixer = unit }
            return unit
        }
        calls.start = { _ in noErr }
        calls.get = { unit, property, scope, element, value, size in
            if property == kAudioOutputUnitProperty_IsRunning {
                value.storeBytes(of: UInt32(1), as: UInt32.self)
                return noErr
            }
            let status = get(unit, property, scope, element, value, size)
            if status == noErr, property == kAudioUnitProperty_StreamFormat {
                var format = value.load(as: AudioStreamBasicDescription.self)
                format.mSampleRate = outputRate
                format.mChannelsPerFrame = outputChannels
                value.storeBytes(of: format, as: AudioStreamBasicDescription.self)
            }
            return status
        }
        let platform = IOSAudio.platform(environment: {
            AudioEnvironment(host: "", link: "unknown", jitterMs: 0)
        }, session: session, outputCalls: calls)
        let decoder = AudioDecoder(platform: platform)
        let opus = OpusConfig(sampleRate: 48_000, channelCount: 2, streams: 1,
                              coupledStreams: 1, samplesPerFrame: 240, mapping: [0, 1])
        #expect(decoder.initialize(audioConfig: 0x000302CA, opus: opus) == 0)
        defer { decoder.shutdown() }
        decoder.routeListenerQueue.sync { decoder.renderMonitor?.cancel() }
        let receiver = RtpAudioReceiver(host: .ipv4(.loopback), audioPort: 0, pingPayload: [],
            audioPacketDuration: 5, opusConfig: opus, audioConfig: 0x000302CA,
            audioEncryption: true, aesKey: Self.key, aesIvId: [0, 0, 0, 1], sink: decoder)
        let before = AudioPipelineTelemetry.shared.takeSnapshot()
        // Swap a pair within each FEC block to exercise the queue's ordered drain as well as its fast path.
        let sequences: [UInt16] = [0, 1, 3, 2, 4, 5, 7, 6, 8, 9, 11, 10, 12, 13, 15, 14]
        for (index, sequence) in sequences.enumerated() {
            let packet = try Self.encryptedPacket(sequence)
            receiver.handleDatagram(packet, count: packet.count,
                                    arrival: 1_000_000_000 + UInt64(index) * 5_000_000)
        }
        #expect(receiver.firstRtpReceived.isSet)
        #expect(receiver.loggedDecryptFailure == false)
        let output = try #require(decoder.halOutput)
        #expect(output.queue.pointee.written.load(ordering: .acquiring) > 0)
        #expect(output.queue.pointee.enabled.load(ordering: .acquiring) == true)
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: output.sampleRate,
                                               channels: output.channels, interleaved: false))
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
        pcm.frameLength = 512
        var timestamp = AudioTimeStamp()
        timestamp.mFlags = .sampleTimeValid
        output.queue.pointee.outputProbe.requested.store(true, ordering: .releasing)
        var flags = AudioUnitRenderActionFlags()
        #expect(AudioUnitRender(try #require(mixer), &flags, &timestamp, 0, 512, pcm.mutableAudioBufferList) == noErr)
        #expect(output.queue.pointee.consumed.load(ordering: .acquiring) > 0)
        decoder.stateLock.withLock { _ = decoder.observeRenderClock() }
        output.observeOutputSilence(now: output.outputSilence.lastObservation + 1_000_000_000)
        let after = AudioPipelineTelemetry.shared.takeSnapshot()
        #expect(after.window.outputProbeResult == 1)
        #expect(after.window.outputProbeInputAudible == true)
        #expect(after.processedDatagrams - before.processedDatagrams == 16)
        #expect(after.decryptOK > before.decryptOK)
        #expect(after.decodedFrames > before.decodedFrames)
        #expect(after.renderedFrames > before.renderedFrames)
        let channels = try #require(pcm.floatChannelData)
        for channel in 0..<Int(format.channelCount) {
            #expect((0..<512).contains { abs(channels[channel][$0]) > 0.00001 })
        }
    }

    @Test(arguments: [true, false])
    func initialInvalidCiphertextReportsDecryptFailure(truncated: Bool) throws {
        let sessionFixture = AudioSessionFixture()
        let platform = IOSAudio.platform(environment: {
            AudioEnvironment(host: "", link: "unknown", jitterMs: 0)
        }, session: sessionFixture.makeSession(), outputCalls: AudioUnitFixture().calls())
        let decoder = AudioDecoder(platform: platform)
        let opus = OpusConfig(sampleRate: 48_000, channelCount: 2, streams: 1,
                              coupledStreams: 1, samplesPerFrame: 240, mapping: [0, 1])
        let receiver = RtpAudioReceiver(host: .ipv4(.loopback), audioPort: 0, pingPayload: [],
            audioPacketDuration: 5, opusConfig: opus, audioConfig: 0x000302CA,
            audioEncryption: true, aesKey: Self.key, aesIvId: [0, 0, 0, 1], sink: decoder)
        var packet = try Self.encryptedPacket(0)
        // A truncated CBC block is deterministically invalid, independent of padding contents.
        if truncated {
            packet.removeLast()
        } else {
            // Flip the final padding byte via the preceding CBC block without changing packet length.
            packet[packet.count - kCCBlockSizeAES128 - 1] ^= 0xFF
        }
        let before = AudioPipelineTelemetry.shared.takeSnapshot()
        receiver.handleDatagram(packet, count: packet.count)
        #expect(receiver.loggedDecryptFailure)
        let after = AudioPipelineTelemetry.shared.takeSnapshot()
        #expect(after.receivedDatagrams == before.receivedDatagrams + 1)
        #expect(after.processedDatagrams == before.processedDatagrams + 1)
        #expect(after.decryptFailed == before.decryptFailed + 1)
        #expect(after.decryptOK == before.decryptOK)
        #expect(after.decodedFrames == before.decodedFrames)
        #expect(receiver.queue.hasSequenceBaseline == false)
    }

    @Test func audioStageCountersExportAndResetWithoutStaleProbeEvidence() {
        let telemetry = AudioPipelineTelemetry()
        telemetry.receivedDatagrams.wrappingAdd(5, ordering: .relaxed)
        telemetry.processedDatagrams.wrappingAdd(4, ordering: .relaxed)
        telemetry.decryptOK.wrappingAdd(3, ordering: .relaxed)
        telemetry.decryptFailed.wrappingAdd(1, ordering: .relaxed)
        telemetry.decodedFrames.wrappingAdd(720, ordering: .relaxed)
        telemetry.renderedFrames.wrappingAdd(512, ordering: .relaxed)
        telemetry.noteOutputProbe(result: 2, inputAudible: true)
        let counts = ["received_datagrams": 5, "processed_datagrams": 4, "decrypt_ok": 3,
                      "decrypt_failed": 1, "decoded_frames": 720, "rendered_frames": 512]
        var json = TelemetryRenderer.NDJSONBuilder()
        var prom = TelemetryRenderer.PromBuilder(session: "test", host: "pc")
        let snapshot = telemetry.takeSnapshot()
        TelemetryRenderer.ndjsonAudioPipeline(&json, snapshot)
        TelemetryRenderer.promAudioPipeline(&prom, snapshot)
        #expect(telemetry.takeSnapshot().window.outputProbeResult == nil)
        for (name, count) in counts {
            #expect(json.line().contains("\"audio_\(name)_total\":\(count)"))
            #expect(prom.out.contains("glimmer_audio_\(name)_total"))
        }
        #expect(json.line().contains("\"audio_output_probe_result\":2"))
        #expect(json.line().contains("\"audio_output_probe_input_audible\":true"))
        telemetry.noteOutputProbe(result: 0, inputAudible: nil)
        #expect(telemetry.takeSnapshot().window.outputProbeInputAudible == nil)
        telemetry.reset()
        var reset = TelemetryRenderer.NDJSONBuilder()
        TelemetryRenderer.ndjsonAudioPipeline(&reset, telemetry.takeSnapshot())
        for name in counts.keys { #expect(reset.line().contains("\"audio_\(name)_total\":0")) }
        #expect(reset.line().contains("audio_output_probe") == false)
    }

    private static func encryptedPacket(_ sequence: UInt16) throws -> [UInt8] {
        let plain = try #require(Data(hex: tone))
        var iv = ((UInt32(1) + UInt32(sequence)).bigEndian, UInt32(0), UInt32(0), UInt32(0))
        var ciphertext = [UInt8](repeating: 0, count: plain.count + kCCBlockSizeAES128)
        var written = 0
        let status = plain.withUnsafeBytes { bytes in
            withUnsafeBytes(of: &iv) { ivBytes in
                CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                        key, key.count, ivBytes.baseAddress, bytes.baseAddress, bytes.count,
                        &ciphertext, ciphertext.count, &written)
            }
        }
        #expect(status == kCCSuccess)
        let timestamp = UInt32(sequence) * 5
        return [0x80, 97, UInt8(sequence >> 8), UInt8(truncatingIfNeeded: sequence),
                UInt8(timestamp >> 24), UInt8(truncatingIfNeeded: timestamp >> 16),
                UInt8(truncatingIfNeeded: timestamp >> 8), UInt8(truncatingIfNeeded: timestamp), 0, 0, 0, 0]
            + ciphertext.prefix(written)
    }
}
