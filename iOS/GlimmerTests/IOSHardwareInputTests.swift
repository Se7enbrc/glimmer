// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import Testing
import UIKit
@testable import Glimmer
@testable import GlimmerEngine

@MainActor
struct IOSHardwareInputTests {
    @Test func gameplayDeliveryDoesNotWaitForMainActor() {
        let backend = InputRecordingBackend()
        let input = StreamInput(backend: backend, emit: { _ in })
        defer { input.stop() }
        input.setFocused(true)
        input.activate(true)
        let capture = IOSHardwareInput(input: input, quit: .defaultQuit, stats: .defaultStats)
        let generation = capture.focus(true)
        let delivered = DispatchSemaphore(value: 0)
        DispatchQueue(label: "hardware-input-test").async {
            let now = ProcessInfo.processInfo.systemUptime
            capture.key(26, pressed: true, modifiers: 1, at: now, generation: generation)
            capture.move(x: 12, y: 7, at: now, generation: generation)
            capture.button(.left, pressed: true, at: now, generation: generation)
            capture.button(.left, pressed: false, at: now, generation: generation)
            capture.button(.right, pressed: true, at: now, generation: generation)
            capture.scroll(x: 1, y: -2, at: now, generation: generation)
            delivered.signal()
        }
        #expect(delivered.wait(timeout: .now() + 2) == .success)
        #expect(backend.keyboard.first?.keyCode == Int16(bitPattern: 0x8057))
        #expect(backend.keyboard.first?.modifiers == 1)
        #expect(backend.mouseMoves == [.init(dx: 12, dy: -7)])
        #expect(backend.pointer == [.button(action: 7, button: 1), .button(action: 8, button: 1),
                                    .button(action: 7, button: 3), .scroll(-240), .hScroll(120)])
        capture.focus(false)
        #expect(backend.keyboard.last?.action == Int8(StreamProtocol.KEY_ACTION_UP))
        #expect(backend.pointer.last == .button(action: 8, button: 3))
    }

    @Test func ownedShortcutsNeverReachThePCIncludingRepeatsAndModifierRelease() {
        let backend = InputRecordingBackend()
        let input = StreamInput(backend: backend, emit: { _ in })
        defer { input.stop() }
        input.setFocused(true)
        input.activate(true)
        let capture = IOSHardwareInput(input: input, quit: .defaultQuit, stats: .defaultStats)
        let generation = capture.focus(true)
        let now = ProcessInfo.processInfo.systemUptime
        for key: UInt16 in [20, 29, 56] {
            capture.key(key, pressed: true, modifiers: 2, at: now, generation: generation)
            capture.key(key, pressed: true, modifiers: 0, at: now, generation: generation)
            capture.key(key, pressed: false, modifiers: 0, at: now, generation: generation)
        }
        #expect(backend.keyboard.isEmpty)
        capture.key(20, pressed: true, modifiers: 0, at: now, generation: generation)
        #expect(backend.keyboard.count == 1)
    }

    @Test(arguments: [false, true])
    func gameplayReleaseKeepsItsOwnerWhenModifiersChange(remapped: Bool) {
        let backend = InputRecordingBackend()
        let input = StreamInput(backend: backend, emit: { _ in })
        defer { input.stop() }
        input.setFocused(true)
        input.activate(true)
        let chord = HotkeyChord(ctrl: true, alt: false, shift: false, cmd: false,
                                keyChar: remapped ? "a" : "z")
        let capture = IOSHardwareInput(input: input, quit: .defaultQuit, stats: chord)
        let generation = capture.focus(true)
        let key: UInt16 = remapped ? 4 : 29
        let now = ProcessInfo.processInfo.systemUptime
        capture.key(key, pressed: true, modifiers: 0, at: now, generation: generation)
        capture.key(224, pressed: true, modifiers: 2, at: now, generation: generation)
        capture.key(key, pressed: true, modifiers: 2, at: now, generation: generation)
        capture.key(key, pressed: false, modifiers: 2, at: now, generation: generation)
        capture.key(224, pressed: false, modifiers: 0, at: now, generation: generation)
        let game = backend.keyboard.filter { $0.keyCode == Int16(bitPattern: remapped ? 0x8041 : 0x805A) }
        #expect(game.map(\.action) == [Int8(StreamProtocol.KEY_ACTION_DOWN), Int8(StreamProtocol.KEY_ACTION_UP)])
        let count = backend.keyboard.count
        input.releaseKeyboardAndPointer()
        #expect(backend.keyboard.count == count)
    }

    @Test func callbacksRetiredByControlsOrFocusLossCannotReplay() {
        let backend = InputRecordingBackend()
        let input = StreamInput(backend: backend, emit: { _ in })
        defer { input.stop() }
        input.setFocused(true)
        input.activate(true)
        let capture = IOSHardwareInput(input: input, quit: .defaultQuit, stats: .defaultStats)
        let old = capture.focus(true)
        capture.focus(false)
        let current = capture.focus(true)
        let now = ProcessInfo.processInfo.systemUptime
        capture.key(4, pressed: true, modifiers: 0, at: now, generation: old)
        capture.move(x: 1, y: 1, at: now, generation: old)
        capture.button(.left, pressed: true, at: now, generation: old)
        #expect(backend.keyboard.isEmpty && backend.mouseMoves.isEmpty && backend.pointer.isEmpty)
        capture.key(4, pressed: true, modifiers: 0, at: now, generation: current)
        #expect(backend.keyboard.count == 1)
    }

    @Test func pointerLockFollowsControlsWindowFocusAndExternalOutput() async throws {
        let fixture = PlaybackFixture()
        let model = fixture.model()
        let outputs = StreamOutputCoordinator(prepareDisplay: { _ in {} },
                                              screenIdentity: { ObjectIdentifier($0) })
        let controller = StreamViewController(model: model, close: {}, outputs: outputs)
        let scene = try await testWindowScene()
        let previous = scene.keyWindow
        let local = UIWindow(windowScene: scene)
        local.rootViewController = controller
        local.makeKeyAndVisible()
        let external = UIWindow(windowScene: scene)
        external.rootViewController = UIViewController()
        defer {
            outputs.end(controller)
            local.isHidden = true
            external.isHidden = true
            local.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        model.start(surface: controller.surface)
        model.receive(fixture.update(.firstFrame))
        model.hardwareConnectionChanged(true)
        for width: CGFloat in [375, 683, 1024] {
            controller.view.frame.size = CGSize(width: width, height: 768)
            controller.viewDidLayoutSubviews()
            model.resumeInput()
            #expect(controller.prefersPointerLocked)
            model.showControls()
            #expect(!controller.prefersPointerLocked)
        }
        model.resumeInput()
        outputs.update(controller)
        outputs.connect(id: "external", role: .windowExternalDisplayNonInteractive, window: external)
        #expect(controller.surface.superview === external.rootViewController?.view)
        #expect(controller.prefersPointerLocked)
        external.makeKeyAndVisible()
        #expect(!controller.prefersPointerLocked)
        local.makeKeyAndVisible()
        #expect(controller.prefersPointerLocked)
        model.stop()
        await model.waitUntilStopped()
        #expect(!controller.prefersPointerLocked)
    }

    @Test func hardwareInputSupportsNarrowWindowsAndReleasesForControls() async {
        let fixture = PlaybackFixture()
        let model = fixture.model()
        model.start(surface: StreamSurface())
        model.receive(fixture.update(.firstFrame))
        model.touchGeometryChanged(usable: false)
        #expect(!model.inputFocused)
        model.hardwareConnectionChanged(true)
        model.resumeInput()
        #expect(model.inputFocused && !model.touchControlsVisible)
        model.showControls()
        #expect(!model.inputFocused)
        model.hardwareConnectionChanged(false)
        #expect(!model.inputFocused && model.controlsVisible)
        model.stop()
        await model.waitUntilStopped()
    }
}
