// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GameController
import GlimmerEngine
import Synchronization
import Testing
@testable import Glimmer

struct IOSControllerFeedbackTests {
    @Test func motorStartsAtSharedIntensityAndDisposesNativeObjectsOnFinalRelease() throws {
        let fixture = MotorFixture()
        var motor: ControllerMotor? = try IOSControllerMotor.make(calls: fixture.calls(), intensity: 0.37)
        weak let retained = motor
        #expect(fixture.events.withLock { $0 } == ["engine.start", "make", "update", "player.start"])
        #expect(fixture.intensities.withLock { $0 } == [0.37])
        motor = nil
        #expect(retained == nil)
        #expect(fixture.events.withLock { $0.suffix(3) } == ["update", "player.stop", "engine.stop"])
        #expect(fixture.intensities.withLock { $0 } == [0.37, 0])
    }

    @Test(arguments: ["engine.start", "make", "update", "player.start"])
    func partialCreationFailureStopsEngineAndAnyPreparedPlayer(stage: String) {
        let fixture = MotorFixture(failure: stage)
        #expect(throws: MotorFixture.Failure.self) {
            try IOSControllerMotor.make(calls: fixture.calls(), intensity: 0.25)
        }
        let events = fixture.events.withLock { $0 }
        #expect(events.last == "engine.stop")
        #expect(events.filter { $0 == "engine.stop" }.count == 1)
        #expect(events.contains("player.stop") == (stage == "update" || stage == "player.start"))
    }

    @MainActor
    @Test func detachedNativeLeaseCannotOverwriteRestoredPlayerIndex() {
        let controller = GCController.withExtendedGamepad()
        controller.playerIndex = .index1
        let feedback = IOSControllerFeedback(controller)
        #expect(feedback.setPlayerIndex(GCControllerPlayerIndex.index2.rawValue))
        feedback.invalidate()
        #expect(controller.playerIndex == .index1)
        #expect(!feedback.setPlayerIndex(GCControllerPlayerIndex.index3.rawValue))
        feedback.invalidate()
        #expect(controller.playerIndex == .index1)
        #expect(!feedback.output().capabilities.contains(.rumble))
    }
}

private final class MotorFixture: Sendable {
    enum Failure: Error { case native }
    let events = Mutex<[String]>([])
    let intensities = Mutex<[Float]>([])
    let failure: String?

    init(failure: String? = nil) { self.failure = failure }

    func record(_ value: String) throws {
        events.withLock { $0.append(value) }
        if failure == value { throw Failure.native }
    }

    func calls() -> IOSControllerMotor.Calls {
        IOSControllerMotor.Calls(start: { try self.record("engine.start") }, player: {
            try self.record("make")
            return IOSControllerMotor.Player(update: { value in
                self.intensities.withLock { $0.append(value) }
                try self.record("update")
            }, start: { try self.record("player.start") }, stop: { try self.record("player.stop") })
        }, stop: { self.events.withLock { $0.append("engine.stop") } })
    }
}
