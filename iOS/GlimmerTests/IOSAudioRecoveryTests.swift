// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AVFAudio
import AudioToolbox
import Foundation
import Testing
@testable import Glimmer
@testable import GlimmerEngine

@Suite(.serialized)
struct IOSAudioRecoveryTests {
    @Test func interruptionWithoutEndRecoversWhilePacketsArrive() throws {
        let fixture = try RecoveryFixture()
        let decoder = fixture.start()
        defer { decoder.shutdown() }
        fixture.sessionFixture.post(AVAudioSession.interruptionNotification, to: fixture.session,
            info: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        decoder.routeListenerQueue.sync {}
        fixture.feedAndCheck(decoder, at: 1_000_000_000)
        fixture.feedAndCheck(decoder, at: 2_010_000_000)
        #expect(decoder.engineRunning)
        #expect(fixture.activations == 2)
        try fixture.expectPCMConsumption(decoder)
    }

    @Test func activationFailureRetriesWithoutReconnect() throws {
        let fixture = try RecoveryFixture()
        fixture.sessionFixture.read { $0.activationFails = true }
        let decoder = fixture.start()
        defer { decoder.shutdown() }
        fixture.feedAndCheck(decoder, at: 1_000_000_000)
        fixture.sessionFixture.read { $0.activationFails = false }
        fixture.feedAndCheck(decoder, at: 2_010_000_000)
        #expect(decoder.engineRunning)
        try fixture.expectPCMConsumption(decoder)
    }

    @Test(arguments: [true, false])
    func stalledOutputReactivatesAndRebuilds(running: Bool) throws {
        let fixture = try RecoveryFixture()
        let decoder = fixture.start()
        defer { decoder.shutdown() }
        fixture.units.read { $0.running = running }
        fixture.feedAndCheck(decoder, at: 1_000_000_000)
        fixture.feedAndCheck(decoder, at: 1_990_000_000)
        #expect(fixture.activations == 1)
        fixture.feedAndCheck(decoder, at: 2_010_000_000)
        #expect(fixture.activations == 2)
        #expect(fixture.units.read { $0.disposed.count } == 3)
        #expect(decoder.engineRunning)
        try fixture.expectPCMConsumption(decoder)
    }

    @Test func retriesBackOffAndDoNotGiveUp() throws {
        let fixture = try RecoveryFixture()
        let decoder = fixture.start()
        defer { decoder.shutdown() }
        fixture.feedAndCheck(decoder, at: 1_000_000_000)
        fixture.sessionFixture.read { $0.activationFails = true }
        fixture.feedAndCheck(decoder, at: 2_000_000_000)
        #expect(fixture.activations == 2)
        for step in 1...19 { fixture.feedAndCheck(decoder, at: 2_000_000_000 + UInt64(step) * 100_000_000) }
        #expect(fixture.activations == 2)
        fixture.feedAndCheck(decoder, at: 4_000_000_000)
        #expect(fixture.activations == 3)
        fixture.feedAndCheck(decoder, at: 8_000_000_000)
        #expect(fixture.activations == 4)
        fixture.sessionFixture.read { $0.activationFails = false }
        fixture.feedAndCheck(decoder, at: 13_000_000_000)
        #expect(fixture.activations == 5)
        #expect(decoder.engineRunning)
    }

    @Test func configurationChangeDuringStartReplacesStaleLease() throws {
        let fixture = try RecoveryFixture()
        let decoder = fixture.start(configurationChange: true)
        defer { decoder.shutdown() }
        decoder.routeListenerQueue.sync {}
        #expect(decoder.engineRunning)
        #expect(fixture.units.read { $0.created.count } == 6)
        #expect(fixture.units.read { $0.disposed.count } == 3)
        try fixture.expectPCMConsumption(decoder)
    }

    @Test func renderingResetsBackoffAndNeverRestartsHealthyOutput() throws {
        let fixture = try RecoveryFixture()
        let decoder = fixture.start()
        defer { decoder.shutdown() }
        fixture.feedAndCheck(decoder, at: 1_000_000_000)
        fixture.feedAndCheck(decoder, at: 2_000_000_000)
        #expect(fixture.activations == 2)
        for tick in 3...12 {
            try fixture.expectPCMConsumption(decoder)
            fixture.check(decoder, at: UInt64(tick) * 1_000_000_000)
        }
        #expect(fixture.activations == 2)
        fixture.feedAndCheck(decoder, at: 13_000_000_000)
        #expect(fixture.activations == 3)
    }

    @Test func failedUnitStartRetriesThroughSessionRecovery() throws {
        let fixture = try RecoveryFixture()
        fixture.units.read { $0.failStart = true }
        let decoder = fixture.start()
        defer { decoder.shutdown() }
        fixture.feedAndCheck(decoder, at: 1_000_000_000)
        fixture.units.read { $0.failStart = false }
        fixture.feedAndCheck(decoder, at: 2_000_000_000)
        #expect(decoder.engineRunning)
        #expect(fixture.activations == 2)
        try fixture.expectPCMConsumption(decoder)
    }

    @Test func idleAndShutdownNeverReactivate() throws {
        let fixture = try RecoveryFixture()
        let decoder = fixture.start()
        for tick in 1...100 { fixture.check(decoder, at: UInt64(tick) * 1_000_000_000) }
        #expect(fixture.activations == 1)
        fixture.feedAndCheck(decoder, at: 101_000_000_000)
        fixture.check(decoder, at: 103_000_000_000)
        #expect(fixture.activations == 1)
        decoder.shutdown()
        fixture.feedAndCheck(decoder, at: 104_000_000_000)
        fixture.feedAndCheck(decoder, at: 106_000_000_000)
        #expect(fixture.activations == 1)
        #expect(decoder.renderMonitor == nil)
    }
}

private final class RecoveryFixture {
    let sessionFixture = AudioSessionFixture()
    let units = AudioUnitFixture()
    let session: IOSAudioSession

    let suite = "IOSAudioRecoveryTests.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() throws {
        session = sessionFixture.makeSession()
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    deinit { defaults.removePersistentDomain(forName: suite) }

    var activations: Int { sessionFixture.read { $0.calls.filter { $0 == "activate" }.count } }

    func start(configurationChange: Bool = false) -> AudioDecoder {
        var calls = units.calls()
        let initialize = calls.initialize
        calls.initialize = { unit in
            let result = initialize(unit)
            if configurationChange, self.units.read({ $0.initialized.count == 1 }) {
                self.sessionFixture.post(AVAudioSession.routeChangeNotification, to: self.session)
            }
            return result
        }
        let platform = IOSAudio.platform(environment: {
            AudioEnvironment(host: "", link: "unknown", jitterMs: 0)
        }, session: session, outputCalls: calls)
        let decoder = AudioDecoder(platform: platform, defaults: defaults)
        let opus = OpusConfig(sampleRate: 48_000, channelCount: 2, streams: 1,
                              coupledStreams: 1, samplesPerFrame: 240, mapping: [0, 1])
        #expect(decoder.initialize(audioConfig: 0x000302CA, opus: opus) == 0)
        decoder.routeListenerQueue.sync { decoder.renderMonitor?.cancel() }
        return decoder
    }

    func feed(_ decoder: AudioDecoder) {
        let hex = "ec7f4bd60777985d8731b747622a18fd2b679a2e9def04904278899d9136b906038d671fa4e046bc58"
            + "abc93cb740be2bcd584efccd910bf0cff90084"
        let chars = Array(hex)
        let packet = stride(from: 0, to: chars.count, by: 2).compactMap { UInt8(String(chars[$0...$0 + 1]), radix: 16) }
        packet.withUnsafeBytes { decoder.decodeAndPlay($0) }
    }

    func feedAndCheck(_ decoder: AudioDecoder, at now: UInt64) {
        feed(decoder)
        check(decoder, at: now)
    }

    func check(_ decoder: AudioDecoder, at now: UInt64) {
        decoder.stateLock.withLock {
            decoder.observeRenderClock()
            decoder.checkOutputHealth(now: now)
        }
        decoder.routeListenerQueue.sync {}
    }

    func expectPCMConsumption(_ decoder: AudioDecoder) throws {
        for _ in 0..<16 { feed(decoder) }
        let output = try #require(decoder.halOutput)
        #expect(output.queue.pointee.enabled.load(ordering: .acquiring) == true)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 240))
        pcm.frameLength = 240
        var flags = AudioUnitRenderActionFlags()
        var timestamp = AudioTimeStamp()
        let callback = output.storage.renderCallback
        let render = try #require(callback.inputProc)
        let context = try #require(callback.inputProcRefCon)
        #expect(render(context, &flags, &timestamp, 0, 240, pcm.mutableAudioBufferList) == noErr)
        #expect(output.queue.pointee.consumed.load(ordering: .acquiring) > 0)
    }
}
