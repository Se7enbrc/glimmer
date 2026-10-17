// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import Foundation
import Observation

extension InputForwarder {
    var releases: InputReleaseLedger {
        _read { inputCore.lock.lock(); defer { inputCore.lock.unlock() }; yield inputCore.releases }
        _modify { inputCore.lock.lock(); defer { inputCore.lock.unlock() }; yield &inputCore.releases }
    }

    var controllerButtons: [UInt8: Int32] {
        _read { inputCore.lock.lock(); defer { inputCore.lock.unlock() }; yield inputCore.buttons }
        _modify { inputCore.lock.lock(); defer { inputCore.lock.unlock() }; yield &inputCore.buttons }
    }

    var controllerAnalogs: [UInt8: GamepadAnalog] {
        _read { inputCore.lock.lock(); defer { inputCore.lock.unlock() }; yield inputCore.analogs }
        _modify { inputCore.lock.lock(); defer { inputCore.lock.unlock() }; yield &inputCore.analogs }
    }

    var touchpadStates: [UInt8: TouchpadState] {
        _read { inputCore.lock.lock(); defer { inputCore.lock.unlock() }; yield inputCore.touchpadStates }
        _modify { inputCore.lock.lock(); defer { inputCore.lock.unlock() }; yield &inputCore.touchpadStates }
    }

    var controllerMouseStates: [UInt8: ControllerMouseState] {
        _read { inputCore.lock.lock(); defer { inputCore.lock.unlock() }; yield inputCore.controllerMouseStates }
        _modify { inputCore.lock.lock(); defer { inputCore.lock.unlock() }; yield &inputCore.controllerMouseStates }
    }

    var heldMouseButtons: Set<Int32> {
        _read { inputCore.lock.lock(); defer { inputCore.lock.unlock() }; yield inputCore.heldMouseButtons }
        _modify { inputCore.lock.lock(); defer { inputCore.lock.unlock() }; yield &inputCore.heldMouseButtons }
    }

    var controllerMouseTask: DispatchSourceTimer? { inputCore.withLock { inputCore.controllerMouseTimer } }

    func publishInputSnapshot(focused: Bool? = nil) {
        let focused = focused ?? (forwardsControllerEvents && !controllerOwnershipSuspended)
        inputCore.publish(.init(ready: isReady, focused: focused,
                                mask: gamepadMask, controllersAnnounced: !controllersNeedAnnouncement,
                                chord: controllerQuitChordProvider(),
                                customChord: customControllerChordProvider(),
                                nintendoSlots: useNintendoLabels ? Set(nintendoControllerTypes.keys) : []),
                          backend: backend)
    }

    func observeControllerConfiguration() {
        let config = withObservationTracking {
            (controllerQuitChordProvider(), customControllerChordProvider())
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.observeControllerConfiguration() }
        }
        inputCore.withLock {
            inputCore.snapshot.chord = config.0
            inputCore.snapshot.customChord = config.1
        }
    }

    func connectInputCore() {
        inputCore.withLock {
            inputCore.onMotionInputEnabled = { slot, enabled in
                ControllerMotion.shared.setInputEnabled(enabled, slot: slot)
            }
            inputCore.onMouseMode = { [weak self] slot, enabled in
                if Thread.isMainThread {
                    MainActor.assumeIsolated { self?.controllerMouseModeChanged(slot: slot, enabled: enabled) }
                } else { DispatchQueue.main.async { self?.controllerMouseModeChanged(slot: slot, enabled: enabled) } }
            }
            inputCore.onActivity = { [weak self] in
                if Thread.isMainThread {
                    MainActor.assumeIsolated { self?.updateReconciliationTimer() }
                } else { DispatchQueue.main.async { self?.updateReconciliationTimer() } }
            }
            inputCore.onCenterPartial = { [weak self] slot in
                DispatchQueue.main.async {
                    guard let self, self.quitChordUsesCentreButtons() else { return }
                    let pad = self.attachedControllers.values.first { $0.slot == slot }?.controller?.extendedGamepad
                    self.quitChordBreadcrumb(.partial, "partial hold on slot \(slot)", pad: pad)
                }
            }
            inputCore.onChord = { [weak self] slot, held, edge in
                if Thread.isMainThread {
                    MainActor.assumeIsolated { self?.capturedChordChanged(slot: slot, held: held, edge: edge) }
                } else {
                    DispatchQueue.main.async { self?.capturedChordChanged(slot: slot, held: held, edge: edge) }
                }
            }
        }
        publishInputSnapshot()
        observeControllerConfiguration()
    }
    func capturedChordChanged(slot: UInt8, held: Bool, edge: UUID) {
        guard inputCore.withLock({ inputCore.chordEdges[slot] == edge && inputCore.chordSlots.contains(slot) == held })
            else { return }
        let pad = attachedControllers.values.first { $0.slot == slot }?.controller?.extendedGamepad
        guard held else {
            cancelQuitChordDwell(reason: "released before the dwell elapsed", pad: pad, slot: slot)
            return
        }
        if let pad {
            armQuitChordDwell(pad: pad, slot: slot, edge: edge)
        } else if let hid = attachedHIDControllers.values.first(where: { $0.slot == slot })?.device {
            armQuitChordDwell(slot: slot, edge: edge) { [weak hid] in hid?.state }
        } else { armQuitChordDwell(slot: slot, edge: edge) { [inputCore] in inputCore.state(slot: slot) } }
    }
}
