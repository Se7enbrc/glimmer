// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import Foundation
import Synchronization
import Testing
@testable import Glimmer

@MainActor
@Suite(.serialized)
struct ControllerLayoutCaptureTests {
    private final class Harness: Sendable {
        struct State: Sendable {
            var sample = ControllerMappingSample()
            var receive: (@Sendable (ControllerMappingSample, TimeInterval) -> Void)?
            var releases = 0
        }
        let state = Mutex(State())

        @MainActor func source() -> ControllerLayoutCaptureSource {
            let sources: [ControllerLayoutSource] = [.button(.a), .button(.b), .button(.menu), .button(.options),
                                                     .button(.leftShoulder), .trigger(.left), .axis(.leftX), .extra("back")]
            return .init(controls: sources.map { .init(id: $0, name: $0.layoutName, symbol: $0.layoutSymbol) },
                extras: ["back"], read: { self.state.withLock { $0.sample } }, acquire: { receive in
                    self.state.withLock { $0.receive = receive }
                    return { self.state.withLock { $0.receive = nil; $0.releases += 1 } }
                })
        }

        func send(_ sample: ControllerMappingSample, at time: TimeInterval) {
            let receive = state.withLock { state in state.sample = sample; return state.receive }
            receive?(sample, time)
        }
    }

    @Test func heldOnEntryMustReleaseAndCaptureCompletesOnlyAfterFreshPressAndRelease() {
        let harness = Harness()
        harness.state.withLock { $0.sample.buttons = ControllerMappedButton.a.rawValue }
        let capture = ControllerLayoutCapture(input: harness.source(), mode: .control)
        capture.start(cancel: {})
        #expect(capture.message == "Release the controls to begin.")
        harness.send(.init(), at: 1)
        harness.send(.init(buttons: ControllerMappedButton.b.rawValue), at: 2)
        #expect(capture.source == nil)
        harness.send(.init(), at: 3)
        #expect(capture.source == .button(.b))
        #expect(capture.finished)
        capture.stop()
        #expect(harness.state.withLock { $0.releases } == 1)
    }

    @Test func ambiguousPressDoesNotSelectAControlAndCanBeRetried() {
        let harness = Harness()
        let capture = ControllerLayoutCapture(input: harness.source(), mode: .control)
        capture.start(cancel: {})
        harness.send(.init(buttons: ControllerMappedButton.a.rawValue | ControllerMappedButton.b.rawValue), at: 1)
        #expect(capture.message == "Press one control at a time.")
        harness.send(.init(), at: 2)
        var extra = ControllerMappingSample()
        extra.setExtra(0, pressed: true)
        harness.send(extra, at: 3)
        harness.send(.init(), at: 4)
        #expect(capture.source == .extra("back"))
        capture.stop()
    }

    @Test func analogCaptureIgnoresDriftAndWaitsForNeutral() {
        let harness = Harness()
        let capture = ControllerLayoutCapture(input: harness.source(), mode: .control)
        capture.start(cancel: {})
        var sample = ControllerMappingSample()
        sample.analog[2] = 4000
        harness.send(sample, at: 1)
        #expect(capture.source == nil)
        sample.analog[2] = 22000
        harness.send(sample, at: 2)
        #expect(capture.source == nil)
        sample.analog[2] = 5000
        harness.send(sample, at: 3)
        #expect(capture.source == .axis(.leftX))
        capture.stop()
    }

    @Test func callbacksQueuedBeforeCancellationCannotChangeTheDraft() {
        let harness = Harness()
        let capture = ControllerLayoutCapture(input: harness.source(), mode: .control)
        capture.start(cancel: {})
        let late = harness.state.withLock { $0.receive }
        harness.send(.init(buttons: ControllerMappedButton.a.rawValue), at: 1)
        capture.stop()
        late?(.init(), 2)
        #expect(capture.source == nil)
        #expect(!capture.finished)
        #expect(harness.state.withLock { $0.releases } == 1)
    }

    @Test func overlappingShortcutIsCapturedWithoutSavingAndEscapeCancels() throws {
        let harness = Harness()
        let capture = ControllerLayoutCapture(input: harness.source(), mode: .shortcut)
        var cancelled = false
        capture.start { cancelled = true }
        let pair = ControllerMappedButton.menu.rawValue | ControllerMappedButton.options.rawValue
        harness.send(.init(buttons: pair), at: 10)
        harness.send(.init(), at: 11.1)
        #expect(cancelled)
        #expect(capture.shortcut.isEmpty)
        capture.stop()
    }
}
