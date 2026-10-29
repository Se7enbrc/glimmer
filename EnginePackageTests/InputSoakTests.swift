// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import Testing
@testable import GlimmerEngine

struct InputSoakTests {
    @Test func thirtyTwoMinuteReleaseLedgerSurvivesRepeatedInterruptions() throws {
        let core = InputCore()
        let backend = SoakInputBackend()
        core.snapshot = .init(ready: true, focused: true, mask: 1)
        core.backend = backend
        for second in 0..<SoakTransport.duration {
            press(core, backend: backend)
            let interruption = second % 5
            switch interruption {
            case 0: try focusOrBackground(core, backend: backend, background: false)
            case 1: try focusOrBackground(core, backend: backend, background: true)
            case 2: try rejectedRelease(core, backend: backend)
            case 3: try lostAcceptedRelease(core, backend: backend)
            default: try detach(core, backend: backend)
            }
            #expect(backend.state.withLock { $0.held.isEmpty }, "Stuck input at \(second)s, case \(interruption)")
            #expect(core.releases.held.isEmpty && core.releases.pending.isEmpty)
            #expect(core.releases.connectionInputs.count <= 3)
            #expect(core.releases.keyReleaseModifiers.isEmpty && core.releases.controllerRemovals.isEmpty)
        }
        #expect(backend.state.withLock { $0.sends > 10_000 && $0.releases > 5_000 })
    }

    private func press(_ core: InputCore, backend: SoakInputBackend) {
        core.snapshot.ready = true
        core.snapshot.focused = true
        let key = VKScanCode(vk: 0x41)
        core.releases.hold(.key(key))
        _ = backend.sendKeyboard(keyCode: key.wireCode, action: Int8(StreamProtocol.KEY_ACTION_DOWN),
                                  modifiers: 0, flags: key.flags)
        core.releases.hold(.mouse(1))
        _ = backend.sendMouseButton(action: Int8(StreamProtocol.BUTTON_ACTION_PRESS), button: 1)
        core.receive(slot: 0, buttons: 1, analog: InputCore.neutral)
    }

    private func focusOrBackground(_ core: InputCore, backend: SoakInputBackend, background: Bool) throws {
        core.releases.releaseAll()
        try #require(core.flushReleases())
        core.snapshot.focused = false
        if background { core.snapshot.ready = false }
        let sends = backend.state.withLock { $0.sends }
        core.receive(slot: 0, buttons: 1, analog: InputCore.neutral)
        #expect(backend.state.withLock { $0.sends } == sends)
    }

    private func rejectedRelease(_ core: InputCore, backend: SoakInputBackend) throws {
        backend.state.withLock { $0.reject = true }
        core.releases.releaseAll()
        #expect(!core.flushReleases())
        #expect(core.releases.pending.count == 3)
        let sends = backend.state.withLock { $0.sends }
        for _ in 0..<100 { core.receive(slot: 0, buttons: 2, analog: InputCore.neutral) }
        #expect(backend.state.withLock { $0.sends } == sends)
        #expect(core.releases.pending.count == 3)
        backend.state.withLock { $0.reject = false }
        try #require(core.flushReleases())
    }

    private func lostAcceptedRelease(_ core: InputCore, backend: SoakInputBackend) throws {
        // Local acceptance is not a PC acknowledgment; retain keyboard/mouse state across replacement.
        backend.state.withLock { $0.loseAcceptedRelease = true }
        core.releases.releaseAll()
        try #require(core.flushReleases())
        #expect(!backend.state.withLock { $0.held.isEmpty })
        core.releases.releaseAll(connectionLost: true)
        backend.state.withLock {
            $0.loseAcceptedRelease = false
            // Sunshine retires controller state with the old connection; keys/buttons need replay.
            $0.held.remove(.controller(0))
        }
        try #require(core.flushReleases())
    }

    private func detach(_ core: InputCore, backend: SoakInputBackend) throws {
        backend.state.withLock { $0.reject = true }
        core.retireController(slot: 0)
        #expect(core.releases.controllerRemovals == [0])
        core.releases.releaseKeyboardAndMouse()
        backend.state.withLock { $0.reject = false }
        try #require(core.flushReleases())
    }
}

extension InputSoakTests {
    @MainActor
    @Test func sessionInputLifecycleReleasesAcrossSixteenRecoveryCycles() throws {
        let input = StreamInput(emit: { _ in })
        defer { input.stop() }
        let descriptor = ControllerDescriptor(kind: .unknown, supportedButtons: [.a], capabilities: .analogTriggers)
        var registration = try #require(input.registerController(descriptor))
        var backend = SoakInputBackend()
        var attempt = UUID()
        try #require(input.rebind(to: backend, attempt: attempt))
        input.setFocused(true)
        input.activate(true, attempt: attempt)
        for second in 0..<SoakTransport.duration where second.isMultiple(of: 30) {
            input.submitController(registration, sample: .init(), capturedAt: ProcessInfo.processInfo.systemUptime)
            input.submitController(registration, sample: .init(buttons: .a, leftTrigger: 0.5),
                                   capturedAt: ProcessInfo.processInfo.systemUptime)
            input.setPointerButton(.left, pressed: true, capturedAt: ProcessInfo.processInfo.systemUptime)
            #expect(backend.state.withLock { $0.held.count } == 2)
            switch (second / 30) % 4 {
            case 0:
                input.setFocused(false)
                #expect(backend.state.withLock { $0.held.isEmpty })
                input.setFocused(true)
            case 1:
                input.setFocused(false)
                input.activate(false, attempt: attempt)
                #expect(backend.state.withLock { $0.held.isEmpty })
                input.activate(true, attempt: attempt)
                input.setFocused(true)
            case 2:
                let retired = registration
                input.unregisterController(retired)
                input.setPointerButton(.left, pressed: false, capturedAt: ProcessInfo.processInfo.systemUptime)
                #expect(backend.state.withLock { $0.held.isEmpty })
                registration = try #require(input.registerController(descriptor))
                input.submitController(retired, sample: .init(buttons: .a),
                                       capturedAt: ProcessInfo.processInfo.systemUptime)
                #expect(backend.state.withLock { $0.held.isEmpty })
            default:
                let retired = attempt
                input.prepareForReplacement(attempt: retired)
                #expect(backend.state.withLock { $0.held.isEmpty })
                backend = SoakInputBackend()
                attempt = UUID()
                try #require(input.rebind(to: backend, attempt: attempt))
                input.activate(true, attempt: attempt)
                input.setFocused(true)
                input.activate(false, attempt: retired)
                #expect(input.core.snapshot.ready)
            }
            #expect(input.core.releases.held.isEmpty && input.core.releases.pending.isEmpty)
            input.reconcile()
        }
        input.stop()
        #expect(!input.rebind(to: SoakInputBackend(), attempt: UUID()))
        #expect(input.registerController(descriptor) == nil)
    }
}
