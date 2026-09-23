//
//  AudioEngineLifecycleTests.swift
//
//  The audio engine's lifecycle edges: route-listener removal that actually
//  removes.
//

import CoreAudio
import Foundation
import Testing
@testable import Glimmer

struct AudioEngineLifecycleTests {

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
}
