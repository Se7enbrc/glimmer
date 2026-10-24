// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

@testable import GlimmerEngine
import Foundation
import os
import Testing

struct StreamInputAttemptTests {
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private var descriptor: ControllerDescriptor {
        ControllerDescriptor(kind: .unknown, supportedButtons: [.a, .b], capabilities: [.analogTriggers])
    }

    @Test func replacementReleasesOldBackendAndRetainsRegistrationWithIndependentRearming() throws {
        let input = StreamInput(emit: { _ in })
        defer { input.stop() }
        #expect(input.core.backend == nil)
        let registration = try #require(input.registerController(descriptor))
        let old = InputRecordingBackend()
        let first = UUID()
        #expect(input.rebind(to: old, attempt: first))
        input.setFocused(true)
        input.activate(true, attempt: first)
        input.submitController(registration, sample: .init(buttons: .a, leftTrigger: 0.5), capturedAt: now)
        input.setPointerButton(.left, pressed: true, capturedAt: now)
        let oldTimestamp = now
        input.prepareForReplacement(attempt: first)
        old.stopConnection()
        #expect(old.controllersAtStop.map(\.buttons) == [ControllerButtons.a.rawValue, 0])
        #expect(old.pointer.count == 2)
        #expect(input.registrations[registration.slot]?.identity == registration)
        #expect(input.core.backend == nil)

        input.submitController(registration, sample: .init(buttons: [.a, .b], leftTrigger: 0.5), capturedAt: now)
        let replacement = InputRecordingBackend()
        let second = UUID()
        #expect(input.rebind(to: replacement, attempt: second))
        input.activate(true, attempt: second)
        input.submitController(registration, sample: .init(buttons: .a), capturedAt: oldTimestamp)
        #expect(replacement.calls.isEmpty)
        input.submitController(registration, sample: .init(buttons: [.a, .b], leftTrigger: 0.5,
                                                         rightTrigger: 0.25), capturedAt: now)
        let held = try #require(replacement.calls.last)
        #expect(held.buttons == 0 && held.analog.leftTrigger == 0)
        #expect(held.analog.rightTrigger == 64)
        #expect(replacement.controllerEvents.first == "arrival")
        input.submitController(registration, sample: .init(buttons: .b), capturedAt: now)
        input.submitController(registration, sample: .init(buttons: [.a, .b], leftTrigger: 0.5), capturedAt: now)
        let rearmed = try #require(replacement.calls.last)
        #expect(rearmed.buttons == ControllerButtons.a.rawValue)
        #expect(rearmed.analog.leftTrigger == 128)
        #expect(old.calls.count == old.controllersAtStop.count)
    }

    @Test func queuedOldActivationAndFeedbackCannotAdoptReplacementAttempt() throws {
        let input = StreamInput(emit: { _ in })
        defer { input.stop(); input.haptics.queue.sync {} }
        let registration = try #require(input.registerController(descriptor))
        let lights = OSAllocatedUnfairLock(initialState: [UInt8]())
        input.attachFeedback(ControllerFeedbackOutput(localities: [], makeMotor: { _, _, _, _ in nil },
            setLight: { red, _, _ in lights.withLock { $0.append(red) } }), to: registration)
        let first = UUID()
        let old = InputRecordingBackend()
        #expect(input.rebind(to: old, attempt: first))
        input.setFocused(true)
        input.activate(true, attempt: first)
        input.haptics.queue.sync {}
        input.lifecycleQueue.suspend()
        input.enqueueActivation(false, attempt: first)
        input.enqueueActivation(true, attempt: first)
        input.prepareForReplacement(attempt: first)
        let replacement = InputRecordingBackend()
        let second = UUID()
        #expect(input.rebind(to: replacement, attempt: second))
        input.activate(true, attempt: second)
        input.lifecycleQueue.resume()
        input.lifecycleQueue.sync {}
        input.prepareForReplacement(attempt: first)
        #expect(input.core.snapshot.ready && input.activeAttempt == second)
        #expect(input.core.backend === replacement)
        input.feedback(slot: UInt16(registration.slot), .rgbLED(red: 1, green: 0, blue: 0), attempt: first)
        input.haptics.queue.sync {}
        #expect(lights.withLock { $0.isEmpty })
        input.feedback(slot: UInt16(registration.slot), .rgbLED(red: 2, green: 0, blue: 0), attempt: second)
        input.haptics.queue.sync {}
        #expect(lights.withLock { $0 } == [2])
    }

    @Test func retainedMotionCaptureRejectsOldAttemptRequestAndDelayedSample() throws {
        let input = StreamInput(emit: { _ in })
        defer { input.stop() }
        let registration = try #require(input.registerController(descriptor))
        let handler = OSAllocatedUnfairLock<(@Sendable (ControllerMotionSample) -> Void)?>(initialState: nil)
        let sample = ControllerMotionSample(acceleration: .zero, rotation: SIMD3(1, 2, 3))
        input.attachMotion(ControllerMotionCapture(hasAcceleration: false, hasRotation: true, read: { sample },
            setHandler: { callback in handler.withLock { $0 = callback } }, setSensorsActive: { _ in }),
            to: registration)
        let first = UUID()
        let old = InputRecordingBackend()
        #expect(input.rebind(to: old, attempt: first))
        input.setFocused(true)
        input.activate(true, attempt: first)
        input.feedback(slot: UInt16(registration.slot), .motion(type: 2, reportRateHz: 100), attempt: first)
        let delayed = try #require(handler.withLock { $0 })
        input.prepareForReplacement(attempt: first)
        let oldCount = old.motions.count
        let second = UUID()
        let replacement = InputRecordingBackend()
        #expect(input.rebind(to: replacement, attempt: second))
        input.activate(true, attempt: second)
        input.feedback(slot: UInt16(registration.slot), .motion(type: 2, reportRateHz: 100), attempt: first)
        delayed(sample)
        #expect(old.motions.count == oldCount && replacement.motions.isEmpty)
        #expect(handler.withLock { $0 == nil })
        input.feedback(slot: UInt16(registration.slot), .motion(type: 2, reportRateHz: 100), attempt: second)
        let fresh = try #require(handler.withLock { $0 })
        fresh(sample)
        #expect(!replacement.motions.isEmpty)
        #expect(old.motions.count == oldCount)
    }

    @Test func terminalStopCannotBeReboundOrRevivedByQueuedActivation() {
        let input = StreamInput(emit: { _ in })
        let attempt = UUID()
        let backend = InputRecordingBackend()
        #expect(input.rebind(to: backend, attempt: attempt))
        input.stop()
        #expect(!input.rebind(to: InputRecordingBackend(), attempt: UUID()))
        input.enqueueActivation(true, attempt: attempt)
        input.lifecycleQueue.sync {}
        #expect(input.registerController(descriptor) == nil)
        #expect(input.core.backend == nil && !input.core.snapshot.ready)
    }
}
