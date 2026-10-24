// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

extension InputCore {
    package func retainMouseTiming(slot: UInt8) {
        guard snapshot.ready, snapshot.focused, snapshot.controllersAnnounced,
              let state = controllerMouseStates[slot], state.isMouse else { return }
        guard Self.controllerMouseMoving(state.analog) else {
            mouseTimings[slot] = nil
            return
        }
        guard let samples = InputTimingContext.take()?.samples() else { return }
        let remaining = max(0, 4096 - (mouseTimings[slot]?.count ?? 0))
        mouseTimings[slot, default: []].append(contentsOf: samples.prefix(remaining))
        #if os(macOS) || GLIMMER_DIAGNOSTICS
        if samples.count > remaining { FrameTimingTracker.shared?.inputTimingDropped.increment() }
        #endif
    }

    @discardableResult
    package func registerController(id: ObjectIdentifier, slot: UInt8, buttons: Int32, analog: GamepadAnalog) -> UUID {
        withLock {
            let token = UUID()
            controllers[id] = ControllerSample(slot: slot, token: token,
                registeredAt: ProcessInfo.processInfo.systemUptime, buttons: buttons, analog: analog)
            return token
        }
    }

    package func removeController(id: ObjectIdentifier) {
        withLock {
            guard let sample = controllers.removeValue(forKey: id) else { return }
            current[sample.slot] = nil
            updateChord(slot: sample.slot, held: false, invalidate: true)
        }
    }

    package func acceptController(id: ObjectIdentifier, token: UUID, buttons: Int32,
                                  axes: ((Float, Float), (Float, Float), (Float, Float)),
                                  chordButtons: Int32, touchpad: ControllerTouchpadSample?, capturedAt: TimeInterval) {
        receiveController(id: id, token: token, buttons: buttons,
            analog: ControllerInputSample.normalizedAnalog(axes), chordButtons: chordButtons,
            touchpad: touchpad, capturedAt: capturedAt)
    }

    package func receiveController(id: ObjectIdentifier, token: UUID, buttons: Int32, analog: GamepadAnalog,
                                   chordButtons: Int32, touchpad: ControllerTouchpadSample? = nil,
                                   capturedAt: TimeInterval) {
        withLock {
            guard let sample = controllers[id], sample.token == token,
                  snapshot.ready, snapshot.focused, capturedAt >= snapshot.acceptEventsAfter,
                  capturedAt >= sample.registeredAt else { return }
            #if os(macOS) || GLIMMER_DIAGNOSTICS
            InputDeliverStamp.shared.stamp(slot: Int(sample.slot), nanos: DispatchTime.now().uptimeNanoseconds)
            defer { _ = InputDeliverStamp.shared.take(slot: Int(sample.slot)) }
            #endif
            controllers[id] = ControllerSample(slot: sample.slot, token: token,
                registeredAt: sample.registeredAt, buttons: buttons, analog: analog)
            receive(slot: sample.slot, buttons: buttons, analog: analog,
                    chordButtons: chordButtons, capturedAt: capturedAt)
            if let touchpad {
                forwardTouchpad(slot: sample.slot, primary: (touchpad.primaryX, touchpad.primaryY),
                                secondary: (touchpad.secondaryX, touchpad.secondaryY),
                                clicked: touchpad.clicked, now: capturedAt)
            }
            retainMouseTiming(slot: sample.slot)
        }
    }

    package func receiveCenterButtons(id: ObjectIdentifier, token: UUID, buttons: Int32, shoulders: Int32,
                                      capturedAt: TimeInterval?) {
        withLock {
            if let capturedAt, capturedAt < snapshot.acceptEventsAfter { return }
            guard snapshot.ready, snapshot.focused, let sample = controllers[id], sample.token == token else { return }
            if let capturedAt, capturedAt < sample.registeredAt { return }
            let centerMask = StreamProtocol.PLAY_FLAG | StreamProtocol.BACK_FLAG
                | StreamProtocol.SPECIAL_FLAG | StreamProtocol.MISC_FLAG
            let merged = (sample.buttons & ~centerMask) | (buttons & centerMask)
            let chord = merged | (shoulders & (StreamProtocol.LB_FLAG | StreamProtocol.RB_FLAG))
            var physical = layouts?.states[Int(sample.slot)]?.last
            if let physicalButtons = physical?.buttons {
                physical?.buttons = (physicalButtons & ~UInt32(bitPattern: centerMask))
                    | UInt32(bitPattern: buttons & centerMask)
                    | UInt32(bitPattern: shoulders & (StreamProtocol.LB_FLAG | StreamProtocol.RB_FLAG))
            }
            receive(slot: sample.slot, buttons: merged, analog: sample.analog,
                    chordButtons: chord, capturedAt: capturedAt, extras: sample.extras, physicalSample: physical)
            retainMouseTiming(slot: sample.slot)
            if !chordSlots.contains(sample.slot), controllerMouseStates[sample.slot]?.isMouse != true,
               buttons & (StreamProtocol.PLAY_FLAG | StreamProtocol.BACK_FLAG) != 0 {
                onCenterPartial?(sample.slot)
            }
        }
    }

    package func receiveHID(slot: UInt8, token: UUID, buttons: Int32, analog: GamepadAnalog, capturedAt: TimeInterval,
                            extras: SIMD2<UInt64> = .zero) {
        withLock {
            guard hidRegistrations[slot] == token, capturedAt >= snapshot.acceptEventsAfter else { return }
            receive(slot: slot, buttons: buttons, analog: analog, capturedAt: capturedAt, extras: extras)
            retainMouseTiming(slot: slot)
        }
    }
}
