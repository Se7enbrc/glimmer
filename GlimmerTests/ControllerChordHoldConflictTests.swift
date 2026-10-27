// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import os
import Testing
@testable import GlimmerEngine

// Replays real press and release orders of the Stop chord through the stream's layout route.
struct ControllerChordHoldConflictTests {
    private static let stop: [ControllerMappedButton] = [.leftShoulder, .rightShoulder, .options, .menu]

    private final class Rig {
        let core = InputCore()
        let backend = InputRecordingBackend()
        let actions = OSAllocatedUnfairLock(initialState: [ControllerShortcutAction]())
        let menus = OSAllocatedUnfairLock(initialState: 0)
        var held: UInt32 = 0
        var time = ProcessInfo.processInfo.systemUptime + 10

        init(menuOpensControls: Bool, shortcuts: ControllerLayoutShortcuts? = nil) throws {
            core.publish(.init(ready: true, focused: true, mask: 1), backend: backend)
            core.withLock { core.controllerMenuOpensControls = menuOpensControls }
            core.onControllerShortcut = { [actions] action in actions.withLock { $0.append(action) } }
            core.onControllerMenu = { [menus] _ in menus.withLock { $0 += 1 } }
            _ = core.announceController(slot: 0, arrival: .init(type: 1, supportedButtons: 0xFFFF, caps: 1))
            let available = Set(ControllerMappedButton.allCases.map { ControllerLayoutSource.button($0) })
                .union([.trigger(.left), .trigger(.right)])
            let configuration = try ControllerLayoutConfiguration(layout: nil, shortcuts: shortcuts,
                available: available, mouse: .init())
            core.configureLayout(configuration, slot: 0, held: .init(), at: time)
        }

        // Moves time forward, firing any hold deadline that falls inside the gap.
        func wait(_ seconds: TimeInterval, jitter: Bool = false) {
            let end = time + seconds
            while time < end {
                let step = jitter ? min(0.008, end - time) : end - time
                if let state = core.layouts?.states[0], let deadline = state.gesture.deadline, deadline <= time + step {
                    core.withLock { core.advanceLayoutHold(state, slot: 0, at: deadline) }
                }
                time += step
                if jitter { deliver() }
            }
        }

        func set(_ button: ControllerMappedButton, _ pressed: Bool) {
            held = pressed ? held | button.rawValue : held & ~button.rawValue
            deliver()
        }

        var lateEcho = false
        var dualSense = false

        // The stream hears the system profile and a physical observer; the second can stamp a little earlier.
        func deliver() {
            // A DualSense's centre buttons reach the stream only through the raw-HID supplement.
            let center = ControllerMappedButton.menu.rawValue | ControllerMappedButton.options.rawValue
            let sample = ControllerMappingSample(buttons: dualSense ? held & ~center : held)
            let supplement = dualSense ? (Int32(bitPattern: held & center), Int32(0)) : nil
            for stamp in lateEcho ? [time, time - 0.002] : [time] {
                core.receive(slot: 0, buttons: Int32(bitPattern: held), analog: InputCore.neutral, capturedAt: stamp,
                             physicalSample: sample, rawSupplement: supplement)
            }
            core.withLock {
                core.layouts?.states[0]?.timer?.cancel()
                core.layouts?.states[0]?.timer = nil
                core.controllerMouseTimer?.cancel()
                core.controllerMouseTimer = nil
            }
        }

        var isMouse: Bool { core.withLock { core.controllerMouseStates[0]?.isMouse == true } }
    }

    private static let orders: [[Int]] = {
        func permutations(_ items: [Int]) -> [[Int]] {
            items.count <= 1 ? [items] : items.indices.flatMap { index in
                var rest = items
                let first = rest.remove(at: index)
                return permutations(rest).map { [first] + $0 }
            }
        }
        return permutations([0, 1, 2, 3])
    }()

    // Variants: bit 0 adds report jitter with a late second source, bit 1 models a DualSense.
    @Test(arguments: [false, true], 0..<4)
    func stopChordFiresWithoutMouseModeOrStrayInputInEveryOrder(menuOpensControls: Bool, variant: Int) throws {
        let jitter = variant & 1 != 0
        let dualSense = variant & 2 != 0
        for press in Self.orders {
            for release in Self.orders {
                let rig = try Rig(menuOpensControls: menuOpensControls)
                rig.lateEcho = jitter
                rig.dualSense = dualSense
                for index in press { rig.set(Self.stop[index], true); rig.wait(0.03, jitter: jitter) }
                rig.wait(0.5, jitter: jitter)
                #expect(rig.actions.withLock { $0 } == [.stop], "press \(press)")
                let after = rig.backend.calls.count
                // Lazy releases: the last button often stays down well past the mouse hold.
                for index in release { rig.wait(0.9, jitter: jitter); rig.set(Self.stop[index], false) }
                rig.wait(0.2, jitter: jitter)
                #expect(!rig.isMouse, "press \(press) release \(release)")
                #expect(rig.menus.withLock { $0 } == 0, "press \(press) release \(release)")
                #expect(rig.backend.calls.dropFirst(after).allSatisfy { $0.buttons == 0 })
                #expect(rig.backend.pointer.isEmpty)
            }
        }
    }

    // rc.20 could drop a latched chord mid-hold; the buttons it had hidden must not return as a fresh lone hold.
    @Test(arguments: [false, true])
    func chordButtonsUncoveredByAResetNeverStartALoneHold(menuOpensControls: Bool) throws {
        let rig = try Rig(menuOpensControls: menuOpensControls)
        for button in Self.stop { rig.set(button, true) }
        rig.wait(0.5)
        #expect(rig.actions.withLock { $0 } == [.stop])
        for button in Self.stop.dropLast() { rig.set(button, false) }
        rig.core.withLock { rig.core.layouts?.states[0]?.gesture.reset() }
        rig.deliver()
        rig.wait(1)
        rig.set(.menu, false)
        #expect(!rig.isMouse && rig.menus.withLock { $0 } == 0)
        rig.wait(0.1)
        rig.set(.menu, true)
        rig.wait(0.8)
        rig.set(.menu, false)
        #expect(menuOpensControls ? rig.menus.withLock { $0 } == 1 : rig.isMouse)
    }

    @Test(arguments: [false, true])
    func slowStopChordWithMenuFirstNeverTogglesMouseMode(menuOpensControls: Bool) throws {
        let rig = try Rig(menuOpensControls: menuOpensControls)
        rig.set(.menu, true)
        rig.wait(0.6)
        for button in Self.stop.dropLast() { rig.set(button, true); rig.wait(0.1) }
        rig.wait(0.5)
        for button in Self.stop.dropLast() { rig.set(button, false) }
        rig.wait(1)
        rig.set(.menu, false)
        #expect(rig.actions.withLock { $0 } == [.stop])
        #expect(!rig.isMouse && rig.menus.withLock { $0 } == 0)
    }

    @Test(arguments: [false, true])
    func abandonedPartialChordNeverHandsMenuItsHoldAction(menuOpensControls: Bool) throws {
        let rig = try Rig(menuOpensControls: menuOpensControls)
        rig.set(.leftShoulder, true)
        rig.set(.menu, true)
        rig.wait(0.2)
        rig.set(.leftShoulder, false)
        rig.wait(1)
        rig.set(.menu, false)
        #expect(rig.actions.withLock { $0.isEmpty })
        #expect(!rig.isMouse && rig.menus.withLock { $0 } == 0)
    }

    @Test(arguments: [false, true])
    func loneMenuHoldStillTogglesMouseModeOrOpensControls(menuOpensControls: Bool) throws {
        let rig = try Rig(menuOpensControls: menuOpensControls)
        rig.set(.menu, true)
        rig.wait(0.8)
        rig.set(.menu, false)
        #expect(menuOpensControls ? rig.menus.withLock { $0 } == 1 : rig.isMouse)
    }

    @Test func remappedChordContainingMenuBlocksItsHoldAction() throws {
        var shortcuts = ControllerLayoutShortcuts()
        shortcuts[.stats] = [.button(.menu), .button(.a), .button(.b)]
        let rig = try Rig(menuOpensControls: false, shortcuts: shortcuts)
        rig.set(.menu, true)
        rig.set(.a, true)
        rig.set(.b, true)
        rig.wait(0.5)
        #expect(rig.actions.withLock { $0 } == [.stats])
        rig.set(.a, false)
        rig.set(.b, false)
        rig.wait(1)
        rig.set(.menu, false)
        #expect(!rig.isMouse)
    }

    @Test func gameSeesNoInputLatencyForOrdinaryPresses() throws {
        let rig = try Rig(menuOpensControls: false)
        rig.set(.a, true)
        #expect(rig.backend.calls.last?.buttons == StreamProtocol.A_FLAG)
        rig.set(.menu, true)
        #expect(rig.backend.calls.last?.buttons == StreamProtocol.A_FLAG | StreamProtocol.PLAY_FLAG)
    }
}
