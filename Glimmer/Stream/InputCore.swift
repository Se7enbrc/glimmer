// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import os

/// The recursive lock serializes snapshots, forwarding and the shared release barrier across capture threads.
final class InputCore: @unchecked Sendable {
    struct Snapshot: Sendable {
        var ready = false
        var focused = false
        var mask: UInt16 = 0
        var controllersAnnounced = true
        var chord: ControllerQuitChord = .none
        var customChord: Set<ControllerButton> = []
        var nintendoSlots: Set<UInt8> = []
        var acceptEventsAfter: TimeInterval = 0
    }

    let lock = NSRecursiveLock()
    var snapshot = Snapshot()
    var backend: StreamingBackend?
    var releases = InputReleaseLedger()
    var buttons: [UInt8: Int32] = [:]
    var analogs: [UInt8: GamepadAnalog] = [:]
    var current: [UInt8: (buttons: Int32, analog: GamepadAnalog)] = [:]
    struct ControllerSample {
        let slot: UInt8
        var buttons: Int32
        var analog: GamepadAnalog
    }
    var hidRegistrations: [UInt8: UUID] = [:]
    var controllers: [ObjectIdentifier: ControllerSample] = [:]
    var touchpadStates: [UInt8: InputForwarder.TouchpadState] = [:]
    var controllerMouseStates: [UInt8: ControllerMouseState] = [:]
    var heldMouseButtons: Set<Int32> = []
    var controllerMouseTimer: DispatchSourceTimer?
    let mouseQueue = DispatchQueue(label: "io.ugfugl.Glimmer.controllerMouse", qos: .userInteractive)
    var mouseTimings: [UInt8: [InputEventTiming]] = [:]
    var onMouseMode: (@Sendable (UInt8, Bool) -> Void)?
    var nextTouchPointerId: UInt32 = 1
    private(set) var failureCodes: Set<Int32> = []
    private let log = Logger(subsystem: "io.ugfugl.Glimmer", category: "Input")
    var chordSlots: Set<UInt8> = []
    var onCenterPartial: (@Sendable (UInt8) -> Void)?
    var onChord: (@Sendable (UInt8, Bool) -> Void)?
    var onActivity: (@Sendable () -> Void)?
    var activityPublished = false
    static let neutral = GamepadAnalog(leftTrigger: 0, rightTrigger: 0,
                                       leftStickX: 0, leftStickY: 0, rightStickX: 0, rightStickY: 0)

    deinit { controllerMouseTimer?.cancel() }

    func record(_ name: StaticString, _ result: Int32) {
        guard result != 0, failureCodes.insert(result).inserted else { return }
        log.error("\(name, privacy: .public) returned \(result) (first occurrence)")
    }

    func withLock<Result>(_ body: () -> Result) -> Result {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    func publish(_ value: Snapshot, backend: StreamingBackend?) {
        withLock {
            var value = value
            value.acceptEventsAfter = snapshot.acceptEventsAfter
            if value.ready != snapshot.ready || value.focused != snapshot.focused {
                value.acceptEventsAfter = ProcessInfo.processInfo.systemUptime
            }
            if self.backend !== backend || (value.ready && !snapshot.ready) { failureCodes.removeAll() }
            snapshot = value
            self.backend = backend
        }
    }

    func state(slot: UInt8) -> (buttons: Int32, analog: GamepadAnalog)? {
        withLock { current[slot] }
    }

    func receive(slot: UInt8, buttons: Int32, analog: GamepadAnalog, chordButtons: Int32? = nil,
                 capturedAt: TimeInterval? = nil) {
        withLock {
            guard snapshot.ready, snapshot.focused, snapshot.mask & (1 << slot) != 0 else { return }
            if let capturedAt, capturedAt < snapshot.acceptEventsAfter { return }
            guard snapshot.controllersAnnounced else {
                flushReleases()
                if !activityPublished { activityPublished = true; onActivity?() }
                return
            }
            current[slot] = (chordButtons ?? buttons, analog)
            let held = heldControllerButtons(buttons: chordButtons ?? buttons,
                                             leftTrigger: analog.leftTrigger, rightTrigger: analog.rightTrigger)
            let chord = InputForwarder.chordSatisfied(snapshot.chord, custom: snapshot.customChord, held: held)
            if chord != chordSlots.contains(slot) {
                if chord { chordSlots.insert(slot) } else { chordSlots.remove(slot) }
                onChord?(slot, chord)
            }
            let isMouse = routeControllerMouse(slot: slot, buttons: buttons, analog: analog,
                                               chordHeld: chord,
                                               now: capturedAt ?? ProcessInfo.processInfo.systemUptime)
            let mapped = ControllerButtonLayout.apply(buttons, useNintendoLabels: snapshot.nintendoSlots.contains(slot))
            if chord {
                guard needsRelease(slot: slot, buttons: mapped, leftDown: analog.leftTrigger > 0,
                                   rightDown: analog.rightTrigger > 0) else { return }
                sendController(slot: slot, buttons: (self.buttons[slot] ?? 0) & mapped, analog: Self.neutral)
            } else if !isMouse {
                sendController(slot: slot, buttons: mapped, analog: analog)
            }
            if !activityPublished { activityPublished = true; onActivity?() }
        }
    }

    func sendController(slot: UInt8, buttons: Int32, analog: GamepadAnalog) {
        guard snapshot.ready, flushReleases() else {
            releases.release(.controller(slot))
            return
        }
        releases.hold(.controller(slot))
        let result = backend?.sendMultiController(num: Int16(slot), mask: Int16(bitPattern: snapshot.mask),
                                                  buttons: buttons, analog: analog) ?? -2
        record("LiSendMultiControllerEvent", result)
        if result == 0 {
            self.buttons[slot] = buttons
            analogs[slot] = analog
            if buttons == 0 && analog == Self.neutral { releases.accepted(.controller(slot)) }
        } else {
            releases.release(.controller(slot))
        }
    }

    func needsRelease(slot: UInt8, buttons: Int32, leftDown: Bool, rightDown: Bool) -> Bool {
        let analog = analogs[slot] ?? Self.neutral
        return (self.buttons[slot] ?? 0) & ~buttons != 0
            || (analog.leftTrigger > 0 && !leftDown) || (analog.rightTrigger > 0 && !rightDown)
    }

    @discardableResult
    func flushReleases() -> Bool {
        guard snapshot.ready else { return releases.pending.isEmpty }
        let count = releases.pending.count
        while let release = releases.pending.first {
            let timing = InputTimingContext.suspend(except: release)
            let result = sendRelease(release)
            timing?.restore()
            record("input release", result)
            guard result == 0 else { return false }
            releases.accepted(release)
            if case .controller(let slot) = release {
                buttons[slot] = 0
                analogs[slot] = Self.neutral
            }
        }
        if count > 0 { releases.flushCount += 1 }
        return true
    }

    private func sendRelease(_ release: InputReleaseLedger.Release) -> Int32 {
        switch release {
        case .key(let key):
            return backend?.sendKeyboard(keyCode: key.wireCode, action: Int8(StreamProtocol.KEY_ACTION_UP),
                                         modifiers: releases.keyReleaseModifiers[key] ?? 0, flags: key.flags) ?? -2
        case .mouse(let button):
            return backend?.sendMouseButton(action: Int8(StreamProtocol.BUTTON_ACTION_RELEASE), button: button) ?? -2
        case .controller(let slot):
            let mask = releases.controllerRemovals.contains(slot) ? snapshot.mask & ~(1 << slot) : snapshot.mask
            return backend?.sendMultiController(num: Int16(slot), mask: Int16(bitPattern: mask),
                                                 buttons: 0, analog: Self.neutral) ?? -2
        }
    }
}
