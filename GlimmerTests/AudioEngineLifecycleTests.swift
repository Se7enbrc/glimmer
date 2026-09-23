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

    /// The per-session listener leak: a Swift closure re-bridges to a new block on
    /// every call, so a Swift-side remove never matched. Removing through the
    /// shim's token must stop the notifications.
    @Test func removedListenerStopsFiring() {
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
        let queue = DispatchQueue(label: "io.ugfugl.Glimmer.tests.listener")
        let fired = DispatchSemaphore(value: 0)
        var status: OSStatus = noErr
        guard let token = gl_audio_listener_add(system, &addr, queue, { _, _ in fired.signal() }, &status) else {
            Issue.record("listener install failed (OSStatus \(status))")
            return
        }
        toggle()
        #expect(fired.wait(timeout: .now() + 2) == .success)
        #expect(fired.wait(timeout: .now() + 2) == .success)
        #expect(gl_audio_listener_remove(system, &addr, queue, token) == noErr)
        toggle()
        #expect(fired.wait(timeout: .now() + 0.5) == .timedOut)
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
