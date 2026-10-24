// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GameController
import GlimmerEngine
import Testing
import Synchronization
@testable import Glimmer

@MainActor
struct IOSControllerCaptureTests {
    @Test func focusedCaptureSubmitsWhileMainThreadIsOccupied() async throws {
        let controller = GCController.withExtendedGamepad()
        let pad = try #require(controller.extendedGamepad)
        let connection = StreamConnection(video: ConnectionTestVideoSink()) { _, _ in }
        let submissions = Mutex(0)
        let capture = IOSControllerCapture(calls: .init(
            register: connection.input.registerController, unregister: connection.input.unregisterController,
            submit: { _, _, _ in submissions.withLock { $0 += 1 } }, focus: { _ in }),
            center: NotificationCenter(), readControllers: { [controller] })
        capture.start()
        capture.setFocused(true)
        let handler = try #require(pad.valueChangedHandler)
        let before = submissions.withLock { $0 }
        #expect(deliverWhileMainIsOccupied(queue: controller.handlerQueue, pad: pad, handler: handler) == .success)
        #expect(submissions.withLock { $0 } == before + 1)
        capture.stop()
        await connection.stop()
    }

    private nonisolated func deliverWhileMainIsOccupied(
        queue: DispatchQueue, pad: GCExtendedGamepad, handler: @escaping GCExtendedGamepadValueChangedHandler
    ) -> DispatchTimeoutResult {
        let delivered = DispatchSemaphore(value: 0)
        // GameController owns callback delivery on this queue; the fixture does not mutate the pad.
        queue.async(execute: DispatchWorkItem {
            handler(pad, pad.buttonA)
            delivered.signal()
        })
        // The deadline only escapes a broken main-queue implementation; no sleep orders the test.
        return delivered.wait(timeout: .now() + 2)
    }

    @Test func callbacksFromPreviousFocusCannotReplayAfterResume() async throws {
        let fixture = ControllerCaptureFixture()
        let pad = try #require(fixture.controller.extendedGamepad)
        let capture = fixture.make()
        capture.start()
        capture.setFocused(true)
        let obsolete = try #require(pad.valueChangedHandler)
        capture.setFocused(false)
        capture.setFocused(true)
        let before = fixture.samples.count
        obsolete(pad, pad.buttonA)
        #expect(fixture.samples.count == before)
        capture.stop()
        await fixture.connection.stop()
    }

    @Test(arguments: ["focus", "detach", "stop"])
    func queuedCallbacksCannotSurviveOwnershipChanges(transition: String) async throws {
        let fixture = ControllerCaptureFixture()
        let pad = try #require(fixture.controller.extendedGamepad)
        let capture = fixture.make()
        capture.start()
        capture.setFocused(true)
        let handler = try #require(pad.valueChangedHandler)
        let queue = fixture.controller.handlerQueue
        try #require(queue !== DispatchQueue.main)
        var expected = fixture.samples.count
        let result = deliverAfterTransition(queue: queue, pad: pad, handler: handler) {
            switch transition {
            case "focus":
                capture.setFocused(false)
                capture.setFocused(true)
            case "detach":
                fixture.visible = false
                capture.refresh()
                fixture.visible = true
                capture.refresh()
            default:
                capture.stop()
            }
            expected = fixture.samples.count
        }
        #expect(result == .success)
        #expect(fixture.samples.count == expected)
        capture.stop()
        await fixture.connection.stop()
    }

    private nonisolated func deliverAfterTransition(
        queue: DispatchQueue, pad: GCExtendedGamepad, handler: @escaping GCExtendedGamepadValueChangedHandler,
        transition: () -> Void
    ) -> DispatchTimeoutResult {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let delivered = DispatchSemaphore(value: 0)
        queue.async(execute: DispatchWorkItem {
            entered.signal()
            release.wait()
            handler(pad, pad.buttonA)
            delivered.signal()
        })
        guard entered.wait(timeout: .now() + 2) == .success else {
            release.signal()
            return .timedOut
        }
        transition()
        release.signal()
        return delivered.wait(timeout: .now() + 2)
    }

    @Test func stopRequestedByConnectionObserverCannotResumeInput() async {
        let fixture = ControllerCaptureFixture()
        let capture = fixture.make()
        capture.start()
        capture.observeConnections { connected in
            if !connected { capture.stop() }
        }
        fixture.visible = false
        capture.setFocused(true)
        #expect(!fixture.events.contains("focus:true"))
        #expect(fixture.samples.isEmpty)
        await fixture.connection.stop()
    }

    @Test func detachDiscoveredDuringResumeCannotReopenInputBehindTheControls() async {
        let fixture = ControllerCaptureFixture()
        let capture = fixture.make()
        capture.start()
        capture.observeConnections { connected in
            if !connected { capture.setFocused(false) }
        }
        fixture.visible = false
        capture.setFocused(true)
        #expect(!fixture.events.contains("focus:true"))
        #expect(fixture.samples.isEmpty)
        capture.stop()
        await fixture.connection.stop()
    }

    @Test func attachDiscoveredDuringResumePublishesFocusOnlyOnce() async {
        let fixture = ControllerCaptureFixture()
        fixture.visible = false
        let capture = fixture.make()
        capture.start()
        capture.observeConnections { connected in
            if connected { capture.setFocused(true) }
        }
        fixture.visible = true
        capture.setFocused(true)
        #expect(fixture.events.filter { $0 == "focus:true" }.count == 1)
        #expect(fixture.samples.count == 1)
        capture.stop()
        await fixture.connection.stop()
    }

    @Test func connectionObservationReportsInitialHotplugAndStopWithoutRepeatedRefreshes() async {
        let fixture = ControllerCaptureFixture()
        let capture = fixture.make()
        var connected: [Bool] = []
        capture.start()
        capture.observeConnections { connected.append($0) }
        capture.refresh()
        #expect(connected == [true])
        fixture.visible = false
        capture.refresh()
        fixture.visible = true
        capture.refresh()
        #expect(connected == [true, false, true])
        capture.stop()
        capture.refresh()
        #expect(connected == [true, false, true, false])
        capture.observeConnections { connected.append($0) }
        #expect(connected.last == false)
        await fixture.connection.stop()
    }

    @Test func playStationGlyphsAdvertiseLayoutWithoutInventingCapabilities() throws {
        let controller = GCController.withExtendedGamepad()
        let pad = try #require(controller.extendedGamepad)
        let buttons = [pad.buttonA, pad.buttonB, pad.buttonX, pad.buttonY]
        let glyphs = ["xmark.circle", "circle.circle", "square.circle", "triangle.circle"]
        for (button, glyph) in zip(buttons, glyphs) { button.unmappedSfSymbolsName = glyph }
        pad.buttonA.sfSymbolsName = "a.circle"
        let descriptor = IOSControllerCapture.descriptor(controller, pad: pad)
        #expect(descriptor.kind == .playStation)
        #expect(descriptor.capabilities == [.analogTriggers])
        #expect(!descriptor.capabilities.contains(.touchpad))
        pad.buttonB.unmappedSfSymbolsName = "b.circle"
        #expect(IOSControllerCapture.descriptor(controller, pad: pad).kind == .unknown)
    }

    @Test func capturePreservesNormalizedAxesAndActualButtons() throws {
        let controller = GCController.withExtendedGamepad()
        let pad = try #require(controller.extendedGamepad)
        pad.leftTrigger.setValue(0.25)
        pad.rightThumbstick.xAxis.setValue(-0.5)
        pad.buttonA.setValue(1)
        let sample = IOSControllerCapture.sample(pad)
        #expect(sample.leftTrigger == 0.25)
        #expect(sample.rightStickX == -0.5)
        #expect(sample.buttons.contains(.a))
        #expect(!sample.buttons.contains(.b))
        let descriptor = IOSControllerCapture.descriptor(controller, pad: pad)
        #expect(descriptor.supportedButtons.contains(.menu))
        #expect(descriptor.capabilities == [.analogTriggers])
        #expect(sample.touchpad == nil)
    }

    @Test func resumeSamplesBeforeOpeningFocusAndRestoresNativeOwnership() async throws {
        let fixture = ControllerCaptureFixture()
        let pad = try #require(fixture.controller.extendedGamepad)
        let priorQueue = DispatchQueue(label: "io.ugfugl.Glimmer.test-controller")
        fixture.controller.handlerQueue = priorQueue
        let priorGesture = pad.buttonMenu.preferredSystemGestureState
        let capture = fixture.make()
        capture.start()
        capture.start()
        #expect(fixture.registrations.count == 1)
        pad.buttonA.setValue(1)
        capture.setFocused(true)
        #expect(fixture.events == ["sample", "focus:true"])
        #expect(fixture.samples.last?.buttons.contains(.a) == true)
        #expect(fixture.controller.handlerQueue !== DispatchQueue.main)
        capture.setFocused(false)
        #expect(fixture.events.last == "focus:false")
        #expect(fixture.controller.handlerQueue === priorQueue)
        #expect(pad.buttonMenu.preferredSystemGestureState == priorGesture)
        #expect(pad.valueChangedHandler == nil)
        capture.stop()
        #expect(fixture.events.suffix(2) == ["focus:false", "remove"])
        await fixture.connection.stop()
    }

    @Test func focusedHotplugSamplesHeldControlsWithoutWaitingForNativeChange() async throws {
        let fixture = ControllerCaptureFixture()
        fixture.visible = false
        let pad = try #require(fixture.controller.extendedGamepad)
        pad.buttonA.setValue(1)
        pad.leftThumbstick.xAxis.setValue(0.5)
        let capture = fixture.make()
        capture.start()
        capture.setFocused(true)
        #expect(fixture.samples.isEmpty)
        fixture.now = 200
        fixture.visible = true
        fixture.center.post(name: .GCControllerDidConnect, object: fixture.controller)
        #expect(fixture.registrations.count == 1)
        #expect(fixture.samples.count == 1)
        #expect(fixture.samples.first?.buttons.contains(.a) == true)
        #expect(fixture.samples.first?.leftStickX == 0.5)
        #expect(fixture.timestamps == [200])
        #expect(fixture.events == ["focus:true", "sample"])
        #expect(pad.valueChangedHandler != nil)
        capture.refresh()
        #expect(fixture.samples.count == 1)
        capture.stop()
        await fixture.connection.stop()
    }

    @Test func detachedRegistrationRejectsAlreadyQueuedCallbackOnSameController() async throws {
        let fixture = ControllerCaptureFixture()
        let pad = try #require(fixture.controller.extendedGamepad)
        let capture = fixture.make()
        capture.start()
        capture.setFocused(true)
        let obsolete = try #require(pad.valueChangedHandler)
        let first = try #require(fixture.registrations.first)
        fixture.visible = false
        capture.refresh()
        fixture.visible = true
        capture.refresh()
        let second = try #require(fixture.registrations.last)
        #expect(first != second)
        #expect(first.slot == second.slot)
        let before = fixture.samples.count
        obsolete(pad, pad.buttonA)
        #expect(fixture.samples.count == before)
        let current = try #require(pad.valueChangedHandler)
        current(pad, pad.buttonA)
        #expect(fixture.samples.count == before + 1)
        #expect(fixture.timestamps.last == pad.lastEventTimestamp)
        capture.stop()
        current(pad, pad.buttonA)
        #expect(fixture.samples.count == before + 1)
        fixture.center.post(name: .GCControllerDidConnect, object: nil)
        #expect(fixture.registrations.count == 2)
        await fixture.connection.stop()
    }
}

@MainActor
private final class ControllerCaptureFixture {
    let controller = GCController.withExtendedGamepad()
    let center = NotificationCenter()
    let connection = StreamConnection(video: ConnectionTestVideoSink()) { _, _ in }
    var visible = true
    var now: TimeInterval = 100
    var registrations: [ControllerRegistration] = []
    private final class Recorded: Sendable {
        let state = Mutex((samples: [ControllerInputSample](), timestamps: [TimeInterval](), events: [String]()))
    }
    private let recorded = Recorded()
    var samples: [ControllerInputSample] { recorded.state.withLock { $0.samples } }
    var timestamps: [TimeInterval] { recorded.state.withLock { $0.timestamps } }
    var events: [String] { recorded.state.withLock { $0.events } }

    func make() -> IOSControllerCapture {
        IOSControllerCapture(calls: .init(register: { [self] descriptor in
            guard let registration = connection.input.registerController(descriptor) else { return nil }
            registrations.append(registration)
            return registration
        }, unregister: { [self] registration in
            recorded.state.withLock { $0.events.append("remove") }
            connection.input.unregisterController(registration)
        }, submit: { [recorded] _, sample, timestamp in
            recorded.state.withLock {
                $0.samples.append(sample)
                $0.timestamps.append(timestamp)
                $0.events.append("sample")
            }
        }, focus: { [self] focus in recorded.state.withLock { $0.events.append("focus:\(focus)") } }), center: center,
           readControllers: { [self] in visible ? [controller] : [] }, clock: { [self] in now })
    }
}
