// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

@testable import GlimmerEngine
import Foundation
import os
import Testing

struct StreamInputChordEdgeTests {
    @MainActor
    @Test func releaseAndRepressCannotCompleteThePreviousDwellWhileMainActorWorkIsQueued() async throws {
        let stops = OSAllocatedUnfairLock(initialState: 0)
        let input = StreamInput(backend: InputRecordingBackend(), emit: { event in
            if event == .stopRequested { stops.withLock { $0 += 1 } }
        })
        defer { input.stop(); input.chordDwell.cancel() }
        input.activate(true)
        input.setFocused(true)
        input.setStopChord(.shoulders)
        let held: ControllerButtons = [.leftShoulder, .rightShoulder]
        let registration = try #require(input.registerController(
            .init(kind: .unknown, supportedButtons: held, capabilities: [])))
        input.submitController(registration, sample: .init(buttons: held),
                               capturedAt: ProcessInfo.processInfo.systemUptime)
        for _ in 0..<100 where input.chordDwell.task == nil { await Task.yield() }
        try #require(input.chordDwell.task != nil)
        #expect(stops.withLock { $0 } == 0)

        // Capture can release and repress before MainActor processes either edge.
        input.submitController(registration, sample: .init(), capturedAt: ProcessInfo.processInfo.systemUptime)
        input.submitController(registration, sample: .init(buttons: held),
                               capturedAt: ProcessInfo.processInfo.systemUptime)
        input.chordDwell.expire()
        #expect(stops.withLock { $0 } == 0)
    }
    @MainActor
    @Test func queuedOldRegistrationReleaseCannotCancelReplacementDwell() async throws {
        let stops = OSAllocatedUnfairLock(initialState: 0)
        let input = StreamInput(backend: InputRecordingBackend(), emit: { event in
            if event == .stopRequested { stops.withLock { $0 += 1 } }
        })
        defer { input.stop(); input.chordDwell.cancel() }
        input.activate(true)
        input.setFocused(true)
        input.setStopChord(.shoulders)
        let held: ControllerButtons = [.leftShoulder, .rightShoulder]
        let descriptor = ControllerDescriptor(kind: .unknown, supportedButtons: held, capabilities: [])
        let old = try #require(input.registerController(descriptor))
        input.submitController(old, sample: .init(buttons: held), capturedAt: ProcessInfo.processInfo.systemUptime)
        for _ in 0..<100 where input.chordDwell.task == nil { await Task.yield() }
        try #require(input.chordDwell.task != nil)
        input.unregisterController(old)
        let replacement = try #require(input.registerController(descriptor))
        #expect(replacement.slot == old.slot)
        input.submitController(replacement, sample: .init(buttons: held),
                               capturedAt: ProcessInfo.processInfo.systemUptime)
        input.chordDwell.expire()
        #expect(stops.withLock { $0 } == 0)
        for _ in 0..<100 where input.chordDwell.task == nil { await Task.yield() }
        try #require(input.chordDwell.task != nil)
        input.chordDwell.expire()
        #expect(stops.withLock { $0 } == 1)
    }
}
