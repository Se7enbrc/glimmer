// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AVFAudio
import AudioToolbox
import GlimmerEngine
import Testing
@testable import Glimmer

@Suite(.serialized)
struct IOSAudioOutputTests {
    @Test func graphUsesActualHardwareFormatAndEngineCallbacks() throws {
        let sessionFixture = AudioSessionFixture()
        let session = sessionFixture.makeSession()
        sessionFixture.observe(session)
        let units = AudioUnitFixture()
        let lease = try session.acquire(sampleRate: 48_000)
        var graph: IOSAudioOutput? = IOSAudioOutput(channels: 2, session: session, lease: lease, calls: units.calls())
        try graph?.configure(format: format())
        #expect(graph?.sampleRate == 44_100)
        #expect(graph?.channels == 1)
        #expect(abs((graph?.latencyMs ?? 0) - 32) < 0.0001)
        #expect(units.read { $0.created } == [kAudioUnitSubType_RemoteIO, kAudioUnitSubType_Varispeed,
                                             kAudioUnitSubType_MultiChannelMixer])
        #expect(units.read { $0.formats.map(\.mSampleRate) } == [48_000, 44_100, 44_100, 44_100, 44_100])
        #expect(units.read { $0.formats.map(\.mChannelsPerFrame) } == [2, 2, 2, 1, 1])
        #expect(units.read { $0.callbackContexts } == [graph?.storage.context])
        #expect(graph?.start() == noErr)
        #expect(graph?.isRunning == true)
        sessionFixture.close(session)
        graph = nil
        let handles = units.read { $0.handles }
        #expect(units.read { $0.initialized } == [handles[1], handles[2], handles[0]])
        #expect(units.read { $0.disposed } == [handles[0], handles[2], handles[1]])
        #expect(sessionFixture.read { $0.calls.last } == "deactivate")
    }

    @Test func unresolvedRemoteIORateUsesActivatedSessionRate() throws {
        let fixture = AudioSessionFixture()
        let session = fixture.makeSession()
        fixture.observe(session)
        let units = AudioUnitFixture()
        units.read { $0.hardwareRate = 0; $0.hardwareChannels = 2 }
        let lease = try session.acquire(sampleRate: 48_000)
        let graph = IOSAudioOutput(channels: 2, session: session, lease: lease, calls: units.calls())
        try graph.configure(format: format())
        #expect(graph.sampleRate == lease.route.sampleRate)
        #expect(units.read { $0.formats.dropFirst().allSatisfy { $0.mSampleRate == 44_100 } })
        #expect(graph.start() == noErr)
        fixture.close(session)
    }

    @Test func sharedOutputOwnsGraphAndReleasesItWhilePlatformRemainsAlive() throws {
        let sessionFixture = AudioSessionFixture()
        let session = sessionFixture.makeSession()
        sessionFixture.observe(session)
        let units = AudioUnitFixture()
        let lease = try session.acquire(sampleRate: 48_000)
        var graph: IOSAudioOutput? = IOSAudioOutput(channels: 2, session: session, lease: lease, calls: units.calls())
        weak let retainedGraph = graph
        weak let retainedStorage = graph?.storage
        try graph?.configure(format: format())
        var output = graph?.sharedOutput
        graph = nil
        #expect(retainedGraph != nil)
        sessionFixture.close(session)
        #expect(!sessionFixture.read { $0.calls.contains("deactivate") })
        #expect(output != nil)
        output = nil
        #expect(retainedGraph == nil)
        #expect(retainedStorage == nil)
        #expect(units.read { $0.disposed.count } == 3)
        #expect(sessionFixture.read { $0.calls.last } == "deactivate")
        #expect(session.sampleRoute().uid == "test-output")
    }

    @Test func initializationFailureDisposesAllCreatedUnits() throws {
        let sessionFixture = AudioSessionFixture()
        let session = sessionFixture.makeSession()
        sessionFixture.observe(session)
        let units = AudioUnitFixture()
        units.read { $0.failInitialization = true }
        let lease = try session.acquire(sampleRate: 48_000)
        var graph: IOSAudioOutput? = IOSAudioOutput(channels: 2, session: session, lease: lease, calls: units.calls())
        #expect(throws: AudioOutput.Failure.self) { try graph?.configure(format: format()) }
        sessionFixture.close(session)
        graph = nil
        #expect(units.read { $0.disposed.count } == 3)
        #expect(sessionFixture.read { $0.calls.last } == "deactivate")
    }

    @Test func failedReaderDisposalDoesNotFreeUpstreamUnits() throws {
        let sessionFixture = AudioSessionFixture()
        let session = sessionFixture.makeSession()
        sessionFixture.observe(session)
        let units = AudioUnitFixture()
        units.read { $0.failDisposal = true }
        let lease = try session.acquire(sampleRate: 48_000)
        var graph: IOSAudioOutput? = IOSAudioOutput(channels: 2, session: session, lease: lease, calls: units.calls())
        try graph?.configure(format: format())
        sessionFixture.close(session)
        graph = nil
        #expect(units.read { $0.disposed } == units.read { Array($0.handles.prefix(1)) })
    }

    @Test func decoderShutdownDisposesOutputWithoutReleasingDecoderOrPlatform() {
        let sessionFixture = AudioSessionFixture()
        let session = sessionFixture.makeSession()
        let units = AudioUnitFixture()
        let platform = IOSAudio.platform(environment: {
            AudioEnvironment(host: "audio-adapter-test", link: "unknown", jitterMs: 0)
        }, session: session, outputCalls: units.calls())
        let decoder = AudioDecoder(platform: platform)
        let opus = OpusConfig(sampleRate: 48_000, channelCount: 2, streams: 1,
                              coupledStreams: 1, samplesPerFrame: 240, mapping: [0, 1])
        #expect(decoder.initialize(audioConfig: 0x000302CA, opus: opus) == 0)
        #expect(units.read { $0.created.count } == 3)
        decoder.shutdown()
        #expect(units.read { $0.disposed.count } == 3)
        #expect(sessionFixture.read { $0.calls.last } == "deactivate")
        #expect(decoder.initialize(audioConfig: 0x000302CA, opus: opus) == 0)
        #expect(units.read { $0.created.count } == 6)
        decoder.shutdown()
        #expect(units.read { $0.disposed.count } == 6)
    }

    @Test func nativeStereoOutputStartsAndRenders() async throws {
        let session = IOSAudioSession()
        let lease = try session.acquire(sampleRate: 48_000)
        defer { session.lock.withLock { session.wantsPlayback = false } }
        let graph = IOSAudioOutput(channels: 2, session: session, lease: lease)
        try graph.configure(format: format())
        #expect(graph.start() == noErr)
        try await Task.sleep(for: .milliseconds(250))
        #expect(graph.isRunning)
        #expect(graph.lastRenderError() == noErr)
    }

    private func format() throws -> AVAudioFormat {
        try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                   channels: 2, interleaved: false))
    }
}
