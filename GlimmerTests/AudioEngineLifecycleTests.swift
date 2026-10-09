//
//  AudioEngineLifecycleTests.swift
//
//  The audio engine's lifecycle edges: the stream-only mute, the guarded
//  engine start, and route-listener removal that actually removes.
//

import AVFAudio
import CoreAudio
import Foundation
import Testing
@testable import Glimmer

struct AudioEngineLifecycleTests {

    /// Once audio is up, muting silences the stream's own mixer immediately and
    /// unmuting restores it.
    @Test func muteTogglesTheStreamMixerOnceAudioIsUp() {
        let decoder = AudioDecoder()
        decoder.inputFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)
        #expect(decoder.inputFormat != nil)
        decoder.setOutputMuted(true)
        #expect(decoder.engine.mainMixerNode.outputVolume == 0)
        decoder.setOutputMuted(false)
        #expect(decoder.engine.mainMixerNode.outputVolume == 1)
    }

    /// The stream start asks for the mute before audio exists; it must survive
    /// until the engine starts and be applied there.
    @Test func muteRequestedBeforeAudioStartsIsAppliedAtStart() {
        let decoder = AudioDecoder()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)
        decoder.engine.attach(decoder.playerNode)
        decoder.engine.connect(decoder.playerNode, to: decoder.engine.mainMixerNode, format: format)
        decoder.setOutputMuted(true)
        decoder.stateLock.lock()
        let failure = decoder.startEngineSafely()
        let volume = decoder.engine.mainMixerNode.outputVolume
        decoder.stateLock.unlock()
        decoder.shutdown()
        // No output device (a headless runner) can't start; there's nothing to mute.
        if failure == nil { #expect(volume == 0) }
    }

    /// An empty graph makes `engine.start()` RAISE: the guarded start must report
    /// a failure instead of aborting the process.
    @Test func guardedStartReportsARaiseInsteadOfCrashing() {
        let decoder = AudioDecoder()
        decoder.stateLock.lock()
        let failure = decoder.startEngineSafely()
        let running = decoder.engine.isRunning
        decoder.stateLock.unlock()
        #expect((failure == nil) == running)
    }

    /// A fresh decoder must not inherit an exhausted restart ladder from the previous connection.
    @Test func reinitializationClearsRestartState() {
        let decoder = AudioDecoder()
        defer { decoder.shutdown() }
        decoder.stateLock.lock()
        decoder.engineRestartRetries = AudioDecoder.maxEngineRestartRetries
        decoder.primeEdgeRetryAtNanos = 1
        decoder.primeEdgeFailureStreak = true
        decoder.stateLock.unlock()
        _ = decoder.initDecoderCore(channelCount: 2, sampleRate: 48_000,
                                    streams: 1, coupledStreams: 1,
                                    samplesPerFrame: 240, mapping: [0, 1])
        decoder.stateLock.lock()
        #expect(decoder.engineRestartRetries <= 1)
        #expect(decoder.primeEdgeRetryAtNanos == 0)
        #expect(!decoder.primeEdgeFailureStreak)
        decoder.stateLock.unlock()
        decoder.shutdown()
        #expect(decoder.decoder == nil)
    }

    @Test(arguments: [false, true])
    func oldSessionRetryCannotConsumeNewLadder(shutdownFirst: Bool) throws {
        let decoder = AudioDecoder()
        defer { decoder.shutdown() }
        let generation = decoder.engineRestartGeneration
        if shutdownFirst { decoder.shutdown() }
        // Invalid opus parameters keep this graph empty regardless of hardware.
        #expect(decoder.initDecoderCore(channelCount: 2, sampleRate: 0,
                                       streams: 1, coupledStreams: 1,
                                       samplesPerFrame: 240, mapping: [0, 1]) == -1)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        decoder.stateLock.lock()
        decoder.inputFormat = format
        let currentGeneration = decoder.engineRestartGeneration
        decoder.stateLock.unlock()
        #expect(currentGeneration != generation)
        decoder.retryEngineStart(attempt: 1, generation: generation)
        decoder.stateLock.lock()
        #expect(decoder.engineRestartRetries == 0)
        #expect(!decoder.engine.isRunning)
        decoder.stateLock.unlock()
        // The current session still retries the same empty graph normally.
        decoder.retryEngineStart(attempt: 1, generation: currentGeneration)
        decoder.stateLock.lock()
        #expect(decoder.engineRestartRetries == 1)
        decoder.stateLock.unlock()
    }

    @Test(arguments: [false, true])
    func recoveryStartUpdatesEngineGauge(primeEdge: Bool) throws {
        let decoder = AudioDecoder()
        defer { decoder.shutdown() }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        decoder.inputFormat = format
        decoder.engine.attach(decoder.playerNode)
        decoder.engine.connect(decoder.playerNode, to: decoder.engine.mainMixerNode, format: format)
        // Offline rendering exercises real engine starts without an output device.
        try decoder.engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 240)
        if primeEdge {
            decoder.stateLock.lock()
            #expect(decoder.startPlayoutAtPrimeEdge())
            decoder.stateLock.unlock()
        } else {
            decoder.retryEngineStart(attempt: 1, generation: decoder.engineRestartGeneration)
        }
        decoder.stateLock.lock()
        #expect(decoder.engine.isRunning)
        decoder.audioMeterLock.lock()
        #expect(decoder.engineRunning)
        decoder.audioMeterLock.unlock()
        decoder.stateLock.unlock()
    }

    @Test(arguments: [false, true])
    func recoveryReconnectsAPartiallyDisconnectedGraph(primeEdge: Bool) throws {
        let decoder = AudioDecoder()
        defer { decoder.shutdown() }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        decoder.inputFormat = format
        decoder.engine.attach(decoder.playerNode)
        decoder.engine.attach(decoder.varispeed)
        decoder.engine.connect(decoder.playerNode, to: decoder.varispeed, format: format)
        decoder.connectOutputGraph(format: format, route: AudioOutputRoute())
        try decoder.engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 240)
        try decoder.engine.start()
        decoder.engine.stop()
        // A route-change exception after disconnecting leaves this exact repair state.
        decoder.engine.disconnectNodeOutput(decoder.varispeed)
        decoder.outputGraphNeedsReconnect = true
        if primeEdge {
            decoder.stateLock.withLock { #expect(decoder.startPlayoutAtPrimeEdge()) }
        } else {
            decoder.retryEngineStart(attempt: 1, generation: decoder.engineRestartGeneration)
        }
        #expect(decoder.engine.isRunning)
        #expect(!decoder.outputGraphNeedsReconnect)
        #expect(decoder.engine.outputConnectionPoints(for: decoder.varispeed, outputBus: 0)
            .contains { $0.node === decoder.engine.mainMixerNode })
    }

    private static let rawListenerFired = DispatchSemaphore(value: 0)

    /// The per-session listener leak: Swift hands a C API a fresh block per call, so a block remove never matched.
    /// The HAL matches a function-pointer listener on function and context, which HALListener builds on: a remove
    /// naming another context leaves it firing, the matching one stops it, and so does HALListener's own remove.
    @Test func listenersAreRemovedByFunctionAndContext() async {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertySleepingIsAllowed,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var original: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &original) == noErr else {
            Issue.record("HAL property read failed")
            return
        }
        // Flip the per-process property and put it back: two change notifications.
        func toggle() {
            for value in [original == 0 ? UInt32(1) : 0, original] {
                var setting = value
                _ = AudioObjectSetPropertyData(system, &addr, 0, nil, size, &setting)
            }
        }
        // Raw API; the contexts are identities only, never dereferenced.
        let proc: AudioObjectPropertyListenerProc = { _, _, _, _ in
            AudioEngineLifecycleTests.rawListenerFired.signal()
            return noErr
        }
        let fired = Self.rawListenerFired
        #expect(AudioObjectAddPropertyListener(system, &addr, proc, UnsafeMutableRawPointer(bitPattern: 0x1)) == noErr)
        toggle()
        #expect(await fired.waitAsync(for: .seconds(2)) == .success)
        #expect(await fired.waitAsync(for: .seconds(2)) == .success)
        _ = AudioObjectRemovePropertyListener(system, &addr, proc, UnsafeMutableRawPointer(bitPattern: 0x2))
        toggle()
        #expect(await fired.waitAsync(for: .seconds(2)) == .success)
        #expect(await fired.waitAsync(for: .seconds(2)) == .success)
        #expect(AudioObjectRemovePropertyListener(system, &addr, proc, UnsafeMutableRawPointer(bitPattern: 0x1)) == noErr)
        toggle()
        #expect(await fired.waitAsync(for: .seconds(0.5)) == .timedOut)

        // HALListener: its handler fires, then goes quiet once removed.
        let handled = DispatchSemaphore(value: 0)
        let added = HALListener.add(system, addr) { handled.signal() }
        #expect(added.status == noErr)
        toggle()
        #expect(await handled.waitAsync(for: .seconds(2)) == .success)
        #expect(await handled.waitAsync(for: .seconds(2)) == .success)
        #expect(HALListener.remove(system, addr, key: added.key) == noErr)
        toggle()
        #expect(await handled.waitAsync(for: .seconds(0.5)) == .timedOut)
    }

    /// A backend that outlives its session must let the decoder, and the
    /// AVAudioEngine it owns, go once the connection stops.
    @Test func stoppedBackendReleasesTheAudioDecoder() {
        let backend = NativeBackend()
        weak var released: AudioDecoder?
        do {
            let decoder = AudioDecoder()
            released = decoder
            backend.attachAudioSink(decoder)
        }
        #expect(released != nil)
        backend.stopConnection()
        #expect(released == nil)
    }
}

extension AudioPlayoutStallTests {
    @Test(arguments: [false, true])
    func graphReplacementDiscardsPendingDrainEvidence(replaceGraph: Bool) throws {
        let decoder = AudioDecoder()
        defer { decoder.shutdown() }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        decoder.inputFormat = format
        decoder.engine.attach(decoder.playerNode)
        decoder.engine.attach(decoder.varispeed)
        decoder.engine.connect(decoder.playerNode, to: decoder.varispeed, format: format)
        decoder.connectOutputGraph(format: format, route: AudioOutputRoute())
        try decoder.engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 240)
        try decoder.engine.start()
        decoder.lastOutputFormat = decoder.engine.outputNode.outputFormat(forBus: 0)
        decoder.outputGraphNeedsReconnect = replaceGraph
        decoder.meterSampleRate = 48_000
        decoder.framesScheduled = 240
        decoder.playoutStarted = true
        decoder.primed = true
        decoder.playoutTargetMs = 60
        decoder.cushionLinkResolved = true
        decoder.meterCompleteOnePlayout(frames: 240)
        decoder.noteArrivalGap(nanos: 5_000_000)
        #expect(decoder.pendingUnderrunTargetMs == 60)

        decoder.handleEngineConfigurationChange()
        #expect(decoder.engine.isRunning)
        #expect(decoder.pendingUnderrunTargetMs == (replaceGraph ? nil : 60))
        #expect(decoder.underrunArrivalGapNanos == (replaceGraph ? 0 : 5_000_000))
        #expect(!decoder.meterRegisterScheduleOrOverrun(frames: 240))

        #expect(decoder.playoutTargetMs == (replaceGraph ? 60 : 70))
        #expect(decoder.learnedFloorMs == (replaceGraph ? 0 : 60))
        #expect(decoder.framesPlayed == 240)
        #expect(decoder.framesScheduled == 480)
    }
}

struct AudioOutputDiagnosticTests {
    @Test func coalescingRetainsBookmarkRangesAndBoundsQueuedWork() {
        var requests = AudioOutputDiagnosticRequests()
        let initialQueued = requests.request(bookmark: nil)
        #expect(initialQueued)
        for marker in UInt64(1)...100 {
            let queued = requests.request(bookmark: marker)
            #expect(!queued)
        }
        let first = requests.take()
        #expect(first.first == 1)
        #expect(first.last == 100)
        // Requests arriving during the HAL read become exactly one successor capture.
        let bookmarkQueued = requests.request(bookmark: 101)
        let automaticQueued = requests.request(bookmark: nil)
        #expect(!bookmarkQueued)
        #expect(!automaticQueued)
        let successorNeeded = requests.finish()
        #expect(successorNeeded)
        let next = requests.take()
        #expect(next.first == 101)
        #expect(next.last == 101)
        let successorFinished = requests.finish()
        #expect(!successorFinished)
        let laterQueued = requests.request(bookmark: nil)
        #expect(laterQueued)
        let automatic = requests.take()
        #expect(automatic.last == nil)
        let laterFinished = requests.finish()
        #expect(!laterFinished)
    }

    @Test func diagnosticFieldsAreFiniteAndContainOnlyOutputState() throws {
        let snapshot = AudioOutputDiagnostic(
            playerGain: 1, mainGain: 0, spatialGain: .nan, sampleRate: 48_000,
            channels: 2, muted: true, running: true, halVolume: 0.75, halMuted: false)
        let fields = snapshot.fields(bookmarks: .init(first: 7, last: 9))
        let data = Data(("{" + fields.joined(separator: ",") + "}").utf8)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == Set([
            "event", "reason", "output_channels", "stream_muted", "engine_running", "default_route_changed",
            "player_gain", "main_mixer_gain", "output_rate_hz", "hal_output_volume", "hal_output_muted",
            "bookmark_first", "bookmark_total"]))
        #expect(object["hal_output_volume"] as? Double == 0.75)
        #expect(object["main_mixer_gain"] as? Double == 0)
        #expect(object["reason"] as? String == "bookmark")
        #expect(object["bookmark_total"] as? Int == 9)
    }

    @Test(arguments: [false, true])
    func unavailableOrChangingRouteOmitsVolume(changed: Bool) throws {
        let snapshot = AudioOutputDiagnostic(
            playerGain: 1, mainGain: 1, spatialGain: nil, sampleRate: 48_000,
            channels: 2, muted: false, running: true, halVolume: changed ? 0.8 : nil,
            halMuted: changed ? false : nil, routeChanged: changed)
        let fields = snapshot.fields(bookmarks: .init())
        let data = Data(("{" + fields.joined(separator: ",") + "}").utf8)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["hal_output_volume"] == nil)
        #expect(object["hal_output_muted"] == nil)
        #expect(object["spatial_mixer_gain"] == nil)
        #expect(object["default_route_changed"] as? Bool == changed)
        #expect(object["reason"] as? String == "configuration")
    }
}
