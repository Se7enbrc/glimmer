// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import os

/// The recursive lock serializes snapshots, forwarding and the shared release barrier across capture threads.
package final class InputCore: @unchecked Sendable {
    package struct Snapshot: Sendable {
        package var ready = false
        package var focused = false
        package var mask: UInt16 = 0
        package var controllersAnnounced = true
        package var chord: ControllerQuitChord = .none
        package var customChord: Set<ControllerButton> = []
        package var nintendoSlots: Set<UInt8> = []
        package var acceptEventsAfter: TimeInterval = 0

        package init(ready: Bool = false, focused: Bool = false, mask: UInt16 = 0,
                     controllersAnnounced: Bool = true, chord: ControllerQuitChord = .none,
                     customChord: Set<ControllerButton> = [], nintendoSlots: Set<UInt8> = [],
                     acceptEventsAfter: TimeInterval = 0) {
            self.ready = ready
            self.focused = focused
            self.mask = mask
            self.controllersAnnounced = controllersAnnounced
            self.chord = chord
            self.customChord = customChord
            self.nintendoSlots = nintendoSlots
            self.acceptEventsAfter = acceptEventsAfter
        }
    }

    package let lock = NSRecursiveLock()
    package var snapshot = Snapshot()
    package var backend: StreamingBackend?
    package var releases = InputReleaseLedger()
    package var announcedControllers: [UInt8: ControllerArrival] = [:]
    package var pendingArrivals: [UInt8: ControllerArrival] = [:]
    package var buttons: [UInt8: Int32] = [:]
    package var analogs: [UInt8: GamepadAnalog] = [:]
    package var current: [UInt8: (buttons: Int32, analog: GamepadAnalog)] = [:]
    package var layouts: ControllerLayoutRouting?
    package var onControllerShortcut: (@Sendable (ControllerShortcutAction) -> Void)?
    package struct ControllerSample {
        package let slot: UInt8
        package let token: UUID
        package let registeredAt: TimeInterval
        package var buttons: Int32
        package var analog: GamepadAnalog
        package var extras = SIMD2<UInt64>.zero

        package init(slot: UInt8, token: UUID, registeredAt: TimeInterval, buttons: Int32,
                     analog: GamepadAnalog, extras: SIMD2<UInt64> = .zero) {
            self.slot = slot
            self.token = token
            self.registeredAt = registeredAt
            self.buttons = buttons
            self.analog = analog
            self.extras = extras
        }
    }
    package var hidRegistrations: [UInt8: UUID] = [:]
    package var controllers: [ObjectIdentifier: ControllerSample] = [:]
    package var pendingTouchReleases: [(slot: UInt8, finger: ControllerTouchpadFinger)] = []
    package var touchpadStates: [UInt8: ControllerTouchpadState] = [:]
    package var controllerMouseMapping = ControllerMouseMapping.standard
    package var controllerMouseStates: [UInt8: ControllerMouseState] = [:]
    package var heldMouseButtons: Set<Int32> = []
    package var mousePollingGeneration: UInt64 = 0
    package var controllerMouseTimer: DispatchSourceTimer?
    package let mouseQueue = DispatchQueue(label: "io.ugfugl.Glimmer.controllerMouse", qos: .userInteractive)
    package var mouseTimings: [UInt8: [InputEventTiming]] = [:]
    package var onMotionInputEnabled: (@Sendable (UInt8, Bool) -> Void)?
    package var onMouseMode: (@Sendable (UInt8, Bool) -> Void)?
    package var pointerResidual = SIMD2<Double>.zero
    var scrollQuantizer = ScrollQuantizer()
    package var nextTouchPointerId: UInt32 = 1
    private(set) var failureCodes: Set<Int32> = []
    private let log = Logger(subsystem: "io.ugfugl.Glimmer", category: "Input")
    package var chordSlots: Set<UInt8> = []
    package var onCenterPartial: (@Sendable (UInt8) -> Void)?
    package var chordEdges: [UInt8: UUID] = [:]
    package var onChord: (@Sendable (UInt8, Bool, UUID) -> Void)?
    package var onActivity: (@Sendable () -> Void)?
    package var activityPublished = false
    package static let neutral = GamepadAnalog(leftTrigger: 0, rightTrigger: 0,
                                       leftStickX: 0, leftStickY: 0, rightStickX: 0, rightStickY: 0)

    package init() {}

    deinit { controllerMouseTimer?.cancel() }

    package func record(_ name: StaticString, _ result: Int32) {
        guard result != 0, failureCodes.insert(result).inserted else { return }
        log.error("\(name, privacy: .public) returned \(result) (first occurrence)")
    }

    package func withLock<Result>(_ body: () -> Result) -> Result {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    package func publish(_ value: Snapshot, backend: StreamingBackend?) {
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

    package func state(slot: UInt8) -> (buttons: Int32, analog: GamepadAnalog)? {
        withLock { current[slot] }
    }

    package var needsReconciliation: Bool {
        !releases.pending.isEmpty || !pendingTouchReleases.isEmpty || !pendingArrivals.isEmpty || !releases.held.isEmpty
            || controllerMouseStates.values.contains { $0.isMouse && ($0.buttons != 0 || $0.analog != Self.neutral) }
    }

    package enum ControllerAcceptance { case gated, chord, mouse, forwarded }

    @discardableResult
    package func receive(slot: UInt8, buttons: Int32, analog: GamepadAnalog, chordButtons: Int32? = nil,
                         capturedAt: TimeInterval? = nil, extras: SIMD2<UInt64> = .zero,
                         physicalSample: ControllerMappingSample? = nil) -> ControllerAcceptance {
        withLock {
            guard snapshot.ready, snapshot.focused, snapshot.mask & (1 << slot) != 0 else { return .gated }
            if let capturedAt, capturedAt < snapshot.acceptEventsAfter { return .gated }
            guard snapshot.controllersAnnounced else {
                flushReleases()
                if !activityPublished { activityPublished = true; onActivity?() }
                return .gated
            }
            if layouts?.states[Int(slot)] == nil, snapshot.chord == .startSelectL1R1 {
                let available = Set(ControllerMappedButton.allCases.map { ControllerLayoutSource.button($0) })
                if let config = try? ControllerLayoutConfiguration(layout: nil, shortcuts: nil, available: available) {
                    if layouts == nil { layouts = ControllerLayoutRouting() }
                    layouts?.states[Int(slot)] = ControllerLayoutRouting.State(config, held: .init(),
                        systemHeld: .init(), acceptAfter: snapshot.acceptEventsAfter)
                }
            }
            if let state = layouts?.states[Int(slot)] {
                return receiveLayout(state, slot: slot,
                    sample: physicalSample ?? .init(buttons: chordButtons ?? buttons, analog: analog, extras: extras),
                    systemSample: .init(buttons: buttons, analog: analog, extras: extras),
                    at: capturedAt ?? ProcessInfo.processInfo.systemUptime)
            }
            current[slot] = (chordButtons ?? buttons, analog)
            let held = heldControllerButtons(buttons: chordButtons ?? buttons,
                                             leftTrigger: analog.leftTrigger, rightTrigger: analog.rightTrigger)
            let chord = ControllerChord.satisfied(snapshot.chord, custom: snapshot.customChord, held: held)
            updateChord(slot: slot, held: chord)
            let isMouse = routeControllerMouse(slot: slot, buttons: buttons, analog: analog,
                                               chordHeld: chord,
                                               now: capturedAt ?? ProcessInfo.processInfo.systemUptime)
            let mapped = ControllerButtonLayout.apply(buttons, useNintendoLabels: snapshot.nintendoSlots.contains(slot))
            if chord {
                guard needsRelease(slot: slot, buttons: mapped, leftDown: analog.leftTrigger > 0,
                                   rightDown: analog.rightTrigger > 0) else { return .chord }
                sendController(slot: slot, buttons: (self.buttons[slot] ?? 0) & mapped, analog: Self.neutral)
            } else if !isMouse {
                sendController(slot: slot, buttons: mapped, analog: analog)
            }
            if !activityPublished, needsReconciliation { activityPublished = true; onActivity?() }
            return chord ? .chord : (isMouse ? .mouse : .forwarded)
        }
    }

    package func sendController(slot: UInt8, buttons: Int32, analog: GamepadAnalog) {
        guard snapshot.ready, flushReleases(), flushControllerArrivals() else {
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

    package func needsRelease(slot: UInt8, buttons: Int32, leftDown: Bool, rightDown: Bool) -> Bool {
        let analog = analogs[slot] ?? Self.neutral
        return (self.buttons[slot] ?? 0) & ~buttons != 0
            || (analog.leftTrigger > 0 && !leftDown) || (analog.rightTrigger > 0 && !rightDown)
    }

    @discardableResult
    package func flushReleases() -> Bool {
        guard snapshot.ready else { return releases.pending.isEmpty && pendingTouchReleases.isEmpty }
        guard flushTouchReleases() else { return false }
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
