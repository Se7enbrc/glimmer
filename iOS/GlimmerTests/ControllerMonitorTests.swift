// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import GameController
import Testing
@testable import Glimmer

@MainActor
struct ControllerMonitorTests {
    @Test func initialConnectionDuplicateAndRemoval() {
        let fixture = ControllerFixture()
        let monitor = fixture.makeMonitor()
        fixture.snapshot = [fixture.controller]
        monitor.start()
        monitor.start()
        monitor.refresh()
        #expect(monitor.controllers == [fixture.controller])
        #expect(fixture.events == [true])
        fixture.snapshot = []
        monitor.refresh()
        #expect(monitor.controllers.isEmpty)
        #expect(fixture.events == [true, false])
        monitor.stop()
    }

    @Test func stoppedMonitorCannotReadOrLogAndCanRestart() {
        let fixture = ControllerFixture()
        let monitor = fixture.makeMonitor()
        monitor.start()
        monitor.stop()
        monitor.stop()
        monitor.refresh()
        #expect(fixture.reads == 1)
        #expect(monitor.controllers.isEmpty)
        #expect(fixture.events.isEmpty)
        monitor.start()
        #expect(fixture.reads == 2)
        monitor.stop()
    }

    @Test func notificationRefreshesConnectedControllers() async {
        let fixture = ControllerFixture()
        let monitor = fixture.makeMonitor()
        monitor.start()
        await withCheckedContinuation { continuation in
            fixture.resume = { continuation.resume() }
            fixture.snapshot = [fixture.controller]
            fixture.center.post(name: .GCControllerDidConnect, object: nil)
        }
        #expect(monitor.controllers == [fixture.controller])
        await withCheckedContinuation { continuation in
            fixture.resume = { continuation.resume() }
            fixture.snapshot = []
            fixture.center.post(name: .GCControllerDidDisconnect, object: nil)
        }
        #expect(monitor.controllers.isEmpty)
        #expect(fixture.events == [true, false])
        monitor.stop()
    }

    @Test func profileDetectionUsesCapabilities() {
        let controller = GCController.withExtendedGamepad()
        let snapshot = ControllerMonitor.connectedControllers([controller])
        #expect(snapshot.count == 1)
        #expect(snapshot.first?.id == ObjectIdentifier(controller))
        #expect(snapshot.first?.hasExtendedGamepad == true)
    }
}

@MainActor
private final class ControllerFixture {
    let center = NotificationCenter()
    let device = NSObject()
    var snapshot: [ControllerSnapshot] = []
    var events: [Bool] = []
    var reads = 0
    var resume: (() -> Void)?

    var controller: ControllerSnapshot {
        ControllerSnapshot(id: ObjectIdentifier(device), name: "Test pad", hasExtendedGamepad: true)
    }

    func makeMonitor() -> ControllerMonitor {
        ControllerMonitor(center: center, readControllers: { [self] in
            reads += 1
            return snapshot
        }, logConnection: { [self] _, connected in
            events.append(connected)
            resume?()
            resume = nil
        })
    }
}
