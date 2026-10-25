// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Testing
import UIKit
@testable import Glimmer

extension StreamSessionTests {
    @Test func lockBeforeAttachmentPreventsDelayedConnection() {
        let fixture = PlaybackFixture()
        let model = fixture.model()
        model.availabilityChanged(active: false, background: false, protectedDataAvailable: false)
        model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        model.start(surface: StreamSurface())
        #expect(fixture.makes == 0)
        #expect(model.phase.isEnded)
    }

    @Test func unavailableBackgroundLeaseStopsWithoutReconnect() async {
        let fixture = PlaybackFixture()
        let model = fixture.model()
        model.start(surface: StreamSurface())
        model.availabilityChanged(active: false, background: false, protectedDataAvailable: true)
        #expect(model.phase == .connecting)
        model.availabilityChanged(active: false, background: true, protectedDataAvailable: true)
        await model.waitUntilStopped()
        model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        model.start(surface: StreamSurface())
        #expect(model.phase.isEnded)
        #expect(fixture.makes == 1)
    }

    @Test func briefBackgroundPreservesStreamAndReleasesInput() async {
        let fixture = PlaybackFixture()
        let gate = StreamTestGate()
        var now: TimeInterval = 0
        var ended = 0
        fixture.backgroundCalls = .init(begin: { _ in .init(rawValue: 42) }, end: { _ in ended += 1 },
                                         now: { now }, sleep: { await gate.wait() })
        let model = fixture.model()
        model.start(surface: StreamSurface())
        model.receive(fixture.update(.firstFrame))
        model.resumeInput()
        #expect(model.inputFocused)
        model.availabilityChanged(active: false, background: false, protectedDataAvailable: true)
        model.availabilityChanged(active: false, background: true, protectedDataAvailable: true)
        #expect(model.phase == .streaming && !model.inputFocused)
        #expect(fixture.visibility.last == false)
        now = 5
        model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        #expect(model.phase == .streaming && model.inputFocused)
        #expect(fixture.visibility.last == true)
        #expect(ended == 1 && fixture.completedStops == 0)
        await gate.release()
        model.stop()
        await model.waitUntilStopped()
    }

    @Test func lateForegroundChecksDeadlineBeforeRestoringInputOrPresentation() async {
        let fixture = PlaybackFixture()
        let gate = StreamTestGate()
        var now: TimeInterval = 0
        fixture.backgroundCalls = .init(begin: { _ in .init(rawValue: 42) }, end: { _ in },
                                         now: { now }, sleep: { await gate.wait() })
        let model = fixture.model()
        model.start(surface: StreamSurface())
        model.receive(fixture.update(.firstFrame))
        model.resumeInput()
        model.availabilityChanged(active: false, background: true, protectedDataAvailable: true)
        let focusEdges = fixture.focusHistory.count
        now = 16
        model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        #expect(!model.inputFocused && model.dismissWhenStopped)
        #expect(!fixture.focusHistory.dropFirst(focusEdges).contains(true))
        #expect(fixture.visibility.last == false)
        await gate.release()
        await model.waitUntilStopped()
    }

    @Test func expiredBackgroundDisconnectsAndLateResumeCannotRestart() async {
        let fixture = PlaybackFixture()
        let gate = StreamTestGate()
        let stopping = StreamTestGate()
        fixture.stop = { await stopping.wait() }
        var ended = 0
        fixture.backgroundCalls = .init(begin: { _ in .init(rawValue: 42) }, end: { _ in ended += 1 },
                                         sleep: { await gate.wait() })
        let model = fixture.model()
        model.start(surface: StreamSurface())
        model.receive(fixture.update(.firstFrame))
        model.availabilityChanged(active: false, background: true, protectedDataAvailable: true)
        await gate.waitUntilEntered()
        await gate.release()
        await stopping.waitUntilEntered()
        await stopping.release()
        await model.waitUntilStopped()
        model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        #expect(model.phase.isEnded && model.dismissWhenStopped)
        #expect(fixture.completedStops == 1 && ended == 1)
    }

    @Test func backgroundDuringRecoveryCannotBeRevivedByLateLiveEvent() async {
        let fixture = PlaybackFixture()
        let model = fixture.model()
        model.start(surface: StreamSurface())
        model.receive(fixture.update(.firstFrame))
        model.receive(fixture.update(.reconnecting))
        model.availabilityChanged(active: false, background: true, protectedDataAvailable: true)
        model.receive(fixture.update(.reconnected))
        #expect(model.phase == .stopping && !model.inputFocused)
        await model.waitUntilStopped()
        model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        model.start(surface: StreamSurface())
        #expect(model.phase.isEnded && fixture.makes == 1 && fixture.completedStops == 1)
    }
}
