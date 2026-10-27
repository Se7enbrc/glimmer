// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

@testable import GlimmerEngine
import AppKit
import Carbon.HIToolbox
import Foundation
import os
import Testing
@testable import Glimmer

@Suite(.serialized)
struct InputLatencyTests {
    @Test func mouseModeRetainsEveryStickCaptureUntilOnePollConsumesIt() throws {
        let prior = FrameTimingTracker.shared
        FrameTimingTracker.installForTesting(FrameTimingTracker(
            sessionId: "mouse-mode", traceDirectory: .temporaryDirectory))
        defer { InputTimingContext.end(); FrameTimingTracker.installForTesting(prior) }
        let core = InputCore()
        let samples = OSAllocatedUnfairLock(initialState: [InputEventTiming]())
        let backend = InputRecordingBackend(onInput: {
            if let timing = InputTimingContext.take() { samples.withLock { $0 += timing.samples() } }
        })
        core.publish(.init(ready: true, focused: true, mask: 1), backend: backend)
        core.withLock {
            var state = ControllerMouseState(isMouse: true)
            state.analog = GamepadAnalog(leftTrigger: 0, rightTrigger: 0, leftStickX: 0,
                                         leftStickY: 0, rightStickX: 32767, rightStickY: 0)
            core.controllerMouseStates[0] = state
            for timestamp in [1.0, 1.01] {
                InputTimingContext.begin(source: .rawHID, timestamp: timestamp)
                core.retainMouseTiming(slot: 0)
                InputTimingContext.end()
            }
        }
        core.pollControllerMouse()
        core.pollControllerMouse()
        #expect(backend.mouseMoves.count == 2)
        #expect(samples.withLock { $0.map(\.capture) } == [1_000_000_000, 1_010_000_000])
        #expect(samples.withLock { $0.allSatisfy { $0.source == .rawHID } })
    }

    @Test func rejectedRawMouseCaptureCannotAgeIntoTheNextPoll() {
        let prior = FrameTimingTracker.shared
        FrameTimingTracker.installForTesting(FrameTimingTracker(
            sessionId: "stale-mouse-mode", traceDirectory: .temporaryDirectory))
        defer { InputTimingContext.end(); FrameTimingTracker.installForTesting(prior) }
        let core = InputCore()
        let token = UUID()
        core.publish(.init(ready: true, focused: true, mask: 1), backend: InputRecordingBackend())
        var state = ControllerMouseState(isMouse: true)
        state.analog = GamepadAnalog(leftTrigger: 0, rightTrigger: 0, leftStickX: 0,
                                     leftStickY: 0, rightStickX: 32767, rightStickY: 0)
        core.withLock { core.hidRegistrations[0] = token; core.controllerMouseStates[0] = state }
        InputTimingContext.begin(source: .rawHID, timestamp: 1)
        core.receiveHID(slot: 0, token: token, buttons: 0, analog: state.analog, capturedAt: 1)
        #expect(core.withLock { core.mouseTimings.isEmpty })
    }

    @Test func stagesUseCaptureHandlerBatcherFlushAndActualSubmission() throws {
        let latency = InputLatency()
        var sample = InputEventTiming(source: .keyboard, timestamp: 1, handler: 1_003_000_000)
        sample.batcher = 1_005_000_000
        latency.observe(sample, flushed: 1_012_000_000, sent: 1_020_000_000)
        let rows = latency.snapshot().filter { $0.source == .keyboard }
        let expectations: [(InputLatency.Stage, Double)] = [(.captureHandler, 3), (.handlerBatcher, 2),
            (.batcherFlush, 7), (.flushSend, 8), (.captureSend, 20)]
        for (stage, expected) in expectations {
            let row = try #require(rows.first { $0.stage == stage })
            #expect(row.histogram.observationCount == 1)
            #expect(row.maxMs == expected)
            #expect(row.histogram.sumMs == expected)
        }
        #expect(latency.snapshot().filter { $0.source != .keyboard }.allSatisfy {
            $0.histogram.observationCount == 0
        })
    }

    @Test func thresholdsAreStrictAndInvalidTimestampsDoNotPolluteHistograms() throws {
        let latency = InputLatency()
        for ms in [10, 11, 20, 21, 50, 51] {
            latency.observe(source: .rawHID, stage: .captureSend, from: 1_000_000, to: UInt64(ms + 1) * 1_000_000)
        }
        latency.observe(source: .rawHID, stage: .captureSend, from: 0, to: 2)
        latency.observe(source: .rawHID, stage: .captureSend, from: 2, to: 1)
        let row = try #require(latency.snapshot().first { $0.source == .rawHID && $0.stage == .captureSend })
        #expect(row.histogram.observationCount == 6)
        #expect(row.over10 == 5)
        #expect(row.over20 == 3)
        #expect(row.over50 == 1)
        #expect(row.maxMs == 51)
        #expect(row.histogram.sumMs == 163)
        let p50 = try #require(TelemetryRenderer.histogramQuantile(0.5, stage: row.histogram))
        #expect(p50 == 20)
    }

    @Test func futureCaptureIsRejectedEvenIfSubmissionEventuallyPassesIt() throws {
        let sample = InputEventTiming(source: .keyboard, timestamp: 2, handler: 1_000_000_000)
        #expect(sample.capture == 0)
        let latency = InputLatency()
        latency.observe(sample, flushed: 2_500_000_000, sent: 3_000_000_000)
        let capture = try #require(latency.snapshot().first {
            $0.source == .keyboard && $0.stage == .captureSend
        })
        #expect(capture.histogram.observationCount == 0)
    }

    @Test func ndjsonIncludesCountsMaximaAndQuantiles() {
        let latency = InputLatency()
        latency.observe(source: .mouse, stage: .captureSend, from: 1, to: 60_000_001)
        var json = TelemetryRenderer.NDJSONBuilder()
        TelemetryRenderer.ndjsonInputLatency(&json, latency.snapshot())
        #expect(json.line().contains("\"input_mouse_capture_send_max_ms\":60"))
        #expect(json.line().contains("\"input_mouse_capture_send_over_50ms\":1"))
        #expect(json.line().contains("input_mouse_capture_send_p99_ms"))
        #expect(json.line().contains("input_mouse_capture_send_buckets"))
        #expect(!json.line().contains("input_keyboard_capture_send"))
    }

    @Test func callbackGateRequiresFreshLocalProgress() {
        #expect(!InputCallbackProbe.shouldGate(backlogged: false, responsiveAge: 0))
        #expect(!InputCallbackProbe.shouldGate(backlogged: true, responsiveAge: nil))
        #expect(InputCallbackProbe.shouldGate(backlogged: true, responsiveAge: 1_000_000))
        #expect(InputCallbackProbe.shouldGate(backlogged: true, responsiveAge: 2_000_000))
        #expect(!InputCallbackProbe.shouldGate(backlogged: true, responsiveAge: 2_000_001))
        #expect(!InputCallbackProbe.shouldGate(backlogged: true, responsiveAge: 100_000_000))
    }
    @Test func callbackProbeRetainsFreshGateWhileSubmittingItsNextProbe() {
        let clock = OSAllocatedUnfairLock(initialState: UInt64(10_000_000))
        let probe = InputCallbackProbe(now: { clock.withLock { $0 } })
        let queue = DispatchQueue(label: "input-probe-test")
        #expect(!probe.allowsGate(on: queue))
        queue.sync {}
        queue.suspend()
        #expect(probe.allowsGate(on: queue))
        clock.withLock { $0 += 2_000_001 }
        #expect(!probe.allowsGate(on: queue))
        queue.resume()
        queue.sync {}
        #expect(probe.allowsGate(on: queue))
        queue.sync {}
    }

    @Test func coalescedEventsKeepIndividualTimesAndReconciliationCannotConsumeThem() throws {
        let tracker = FrameTimingTracker(sessionId: "input-test", traceDirectory: .temporaryDirectory)
        let prior = FrameTimingTracker.shared
        FrameTimingTracker.installForTesting(tracker)
        defer { InputTimingContext.end(); FrameTimingTracker.installForTesting(prior) }
        InputTimingContext.begin(source: .mouse, timestamp: 1)
        InputTimingContext.coalesced(timestamp: 1.1)
        let pause = InputTimingContext.suspend()
        #expect(InputTimingContext.take() == nil)
        pause?.restore()
        let captured = try #require(InputTimingContext.take())
        let samples = captured.samples()
        #expect(samples.map(\.capture) == [1_000_000_000, 1_100_000_000])
        #expect(samples.allSatisfy { $0.batcher == captured.batcher })
        #expect(InputTimingContext.take() == nil)
    }

    @Test func submissionAndCompletionRemainDistinctObservations() throws {
        let tracker = FrameTimingTracker(sessionId: "input-test", traceDirectory: .temporaryDirectory)
        let start = DispatchTime.now().uptimeNanoseconds
        var sample = InputEventTiming(source: .controller, timestamp: Double(start - 10_000_000) / 1e9,
                                      handler: start - 5_000_000)
        sample.batcher = start
        let batch = try #require(InputTimingBatch([sample], tracker: tracker))
        let sent = batch.flushed + 1_000_000
        batch.submitted(at: sent)
        batch.completed(sent: sent, at: sent + 21_000_000)
        let rows = tracker.inputLatency.snapshot().filter { $0.source == .controller }
        #expect(rows.first { $0.stage == .sendCompletion }?.maxMs == 21)
        #expect(rows.first { $0.stage == .flushSend }?.maxMs == 1)
        #expect(rows.allSatisfy { $0.histogram.observationCount == 1 })
    }
    @Test @MainActor func physicalReleasesKeepTimingThroughReconciliation() throws {
        let tracker = FrameTimingTracker(sessionId: "release-timing", traceDirectory: .temporaryDirectory)
        let prior = FrameTimingTracker.shared
        FrameTimingTracker.installForTesting(tracker)
        defer { InputTimingContext.end(); FrameTimingTracker.installForTesting(prior) }
        let samples = OSAllocatedUnfairLock(initialState: [InputEventTiming]())
        let backend = InputRecordingBackend(onInput: {
            if let capture = InputTimingContext.take() { samples.withLock { $0 += capture.samples() } }
        })
        let input = InputForwarder()
        input.backend = backend
        input.isReady = true
        input.physicalKeyState = { _ in false }
        input.currentModifierFlags = { [] }
        input.currentMouseButtons = { 0 }
        let view = StreamInputView()
        let stale = VKScanCode(vk: 0x41)
        let physical = VKScanCode(vk: 0x57)
        input.releases.hold(.key(stale))
        input.releases.release(.key(stale))
        input.releases.hold(.key(physical))
        input.physicalKeys[UInt16(kVK_ANSI_W)] = physical
        input.lastInputEventTime = 0
        let key = try #require(NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [],
            timestamp: 1, windowNumber: 0, context: nil, characters: "w", charactersIgnoringModifiers: "w",
            isARepeat: false, keyCode: UInt16(kVK_ANSI_W)))
        input.streamView(view, handleKeyUp: key)
        #expect(backend.keyboard.count == 2)
        #expect(samples.withLock { $0.map(\.source) } == [.keyboard])
        input.releases.hold(.mouse(StreamProtocol.BUTTON_LEFT))
        input.heldMouseButtons.insert(StreamProtocol.BUTTON_LEFT)
        input.lastInputEventTime = 0
        let mouse = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [],
            timestamp: 2, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        input.streamView(view, handleMouseUp: mouse)
        #expect(samples.withLock { $0.map(\.source) } == [.keyboard, .mouse])
        input.heldModifierVKs.insert(0xA0)
        input.releases.hold(.key(VKScanCode(vk: 0xA0)))
        input.lastInputEventTime = 0
        let modifier = try #require(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [],
            timestamp: 3, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: UInt16(kVK_Shift)))
        input.streamView(view, handleFlagsChanged: modifier)
        #expect(samples.withLock { $0.map(\.capture) } == [1_000_000_000, 2_000_000_000, 3_000_000_000])
    }
}
