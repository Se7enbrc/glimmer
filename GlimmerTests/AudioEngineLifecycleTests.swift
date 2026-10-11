// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AVFAudio
import AudioToolbox
import CoreAudio
import Foundation
import Testing
@testable import Glimmer

struct AudioEngineLifecycleTests {
    @Test func muteTogglesOnlyStreamSamples() {
        let decoder = AudioDecoder()
        decoder.setOutputMuted(true)
        decoder.halOutput = AudioHALOutput(channels: 2)
        decoder.applyOutputMute()
        #expect(decoder.halOutput?.queue.pointee.muted.load(ordering: .relaxed) == true)
        decoder.setOutputMuted(false)
        #expect(decoder.halOutput?.queue.pointee.muted.load(ordering: .relaxed) == false)
        decoder.shutdown()
    }

    @Test func missingGraphReportsFailureWithoutCrashing() {
        let decoder = AudioDecoder()
        #expect(decoder.startEngineSafely() != nil)
        #expect(!decoder.engineRunning)
        decoder.shutdown()
    }

    @Test func reinitializationClearsRestartState() {
        let decoder = AudioDecoder()
        defer { decoder.shutdown() }
        decoder.startOutput = { _ in kAudioUnitErr_Uninitialized }
        decoder.pendingSilenceFrames = 240
        decoder.engineRestartRetries = AudioDecoder.maxEngineRestartRetries
        decoder.primeEdgeRetryAtNanos = 1
        decoder.primeEdgeFailureStreak = true
        _ = decoder.initDecoderCore(channelCount: 2, sampleRate: 48_000,
                                    streams: 1, coupledStreams: 1, samplesPerFrame: 240, mapping: [0, 1])
        #expect(decoder.engineRestartRetries == 1)
        #expect(decoder.pendingSilenceFrames == 0)
        #expect(decoder.primeEdgeRetryAtNanos == 0)
        #expect(!decoder.primeEdgeFailureStreak)
    }

    @Test(arguments: [false, true])
    func oldSessionRetryCannotConsumeNewLadder(shutdownFirst: Bool) throws {
        let decoder = AudioDecoder()
        defer { decoder.shutdown() }
        decoder.startOutput = { _ in kAudioUnitErr_Uninitialized }
        let generation = decoder.engineRestartGeneration
        if shutdownFirst { decoder.shutdown() }
        #expect(decoder.initDecoderCore(channelCount: 2, sampleRate: 0, streams: 1,
            coupledStreams: 1, samplesPerFrame: 240, mapping: [0, 1]) == -1)
        decoder.inputFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)
        decoder.retryEngineStart(attempt: 1, generation: generation)
        #expect(decoder.engineRestartRetries == 0)
        decoder.retryEngineStart(attempt: 1, generation: decoder.engineRestartGeneration)
        #expect(decoder.engineRestartRetries == 1)
    }

    @Test(arguments: [false, true])
    func recoveryReconnectsAndUpdatesEngineGauge(primeEdge: Bool) throws {
        let decoder = AudioDecoder()
        defer { decoder.shutdown() }
        decoder.inputFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)
        decoder.outputGraphNeedsReconnect = true
        decoder.startOutput = { audio in
            #expect(audio.outputGraphNeedsReconnect)
            return noErr
        }
        if primeEdge {
            #expect(decoder.startPlayoutAtPrimeEdge())
        } else {
            decoder.retryEngineStart(attempt: 1, generation: decoder.engineRestartGeneration)
        }
        #expect(decoder.engineRunning)
        #expect(!decoder.outputGraphNeedsReconnect)
    }

    @Test func graphReplacementDiscardsPendingDrainAndClosesDecodeAdmission() throws {
        let decoder = AudioDecoder()
        defer { decoder.shutdown() }
        decoder.inputFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)
        decoder.startOutput = { _ in noErr }
        decoder.pendingUnderrunTargetMs = 60
        decoder.underrunArrivalGapNanos = 5_000_000
        decoder.framesScheduled = 480
        decoder.framesPlayed = 240
        decoder.handleEngineConfigurationChange(changedAt: 123) {
            #expect(decoder.graphChanging)
            let unlocked = decoder.stateLock.try()
            #expect(unlocked)
            if unlocked { decoder.stateLock.unlock() }
            decoder.decodeAndPlayPLC()
        }
        #expect(decoder.engineRunning)
        #expect(decoder.pendingUnderrunTargetMs == nil)
        #expect(decoder.deviceRecoveryStarted == 123)
        #expect(decoder.underrunArrivalGapNanos == 0)
        #expect(decoder.framesPlayed == decoder.framesScheduled)
        #expect(!decoder.primed)
    }

    @Test func teardownInvalidatesRetriesBeforeReleasingTheGraph() throws {
        let decoder = AudioDecoder()
        decoder.inputFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)
        decoder.halOutput = AudioHALOutput(channels: 2)
        weak let released = decoder.halOutput
        let generation = decoder.engineRestartGeneration
        decoder.startOutput = { _ in Issue.record("A stopped session must not restart"); return noErr }
        decoder.shutdown()
        decoder.retryEngineStart(attempt: 1, generation: generation)
        #expect(released == nil)
        #expect(decoder.meterShutdown)
        #expect(!decoder.engineRunning)
        #expect(decoder.deviceListeners.isEmpty)
    }

    @Test func failedStartReplacementDiscardsQueuedPCMWithoutCushionGrowth() throws {
        let decoder = AudioDecoder()
        defer { decoder.shutdown() }
        decoder.halOutput = AudioHALOutput(channels: 2)
        decoder.framesScheduled = 1_440
        decoder.framesPlayed = 240
        decoder.playoutTargetMs = 60
        decoder.pendingSilenceFrames = 240
        decoder.pendingUnderrunTargetMs = 60
        decoder.outputGraphNeedsReconnect = true
        decoder.startOutput = { audio in
            #expect(audio.halOutput == nil)
            #expect(audio.framesPlayed == audio.framesScheduled)
            return kAudioUnitErr_Uninitialized
        }
        #expect(decoder.startEngineSafely() != nil)
        #expect(decoder.playoutTargetMs == 60)
        #expect(decoder.pendingSilenceFrames == 0)
        #expect(decoder.pendingUnderrunTargetMs == nil)
        #expect(!decoder.primed)
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
    /// HAL graph it owns, go once the connection stops.
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
