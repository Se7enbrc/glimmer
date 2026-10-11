// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AppKit
import CoreGraphics

extension InputForwarder {
    func noteInputEvent(keyCode: UInt16? = nil, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if let keyCode { missingPhysicalKeys.remove(keyCode) }
        defer {
            lastInputEventTime = now
            if let keyCode { missingPhysicalKeys.remove(keyCode) }
        }
        if let lastInputEventTime, now - lastInputEventTime > 0.1 { reconcilePhysicalInputs() }
    }

    func reconcilePhysicalInputs() {
        inputCore.lock.lock(); defer { inputCore.lock.unlock() }
        guard !physicalKeys.isEmpty || !heldModifierVKs.isEmpty || !heldMouseButtons.isEmpty
            || !releases.pending.isEmpty else { return }
        let before = physicalKeys.count + heldModifierVKs.count + heldMouseButtons.count
        reconcileKeyboard()
        let mouse = currentMouseButtons()
        for (physical, button) in physicalMouseButtons where (0...4).contains(physical)
            && mouse & (1 << physical) == 0 {
            physicalMouseButtons[physical] = nil
            if !physicalMouseButtons.values.contains(button) { releaseMouse(button) }
        }
        let count = before - physicalKeys.count - heldModifierVKs.count - heldMouseButtons.count
        if count > 0 { releases.reconciledCount += count; reportReleaseRecovery() }
        flushPendingReleases()
    }

    private func reconcileKeyboard() {
        guard let window, let inputView, window.isKeyWindow, window.firstResponder === inputView,
              keyboardMonitoringGranted() else {
            missingPhysicalKeys.removeAll()
            missingModifierVKs.removeAll()
            return
        }
        // Permission and focus make samples meaningful; a second miss rules out transient state lag.
        let missing = Set(physicalKeys.keys.filter { !physicalKeyState($0) })
        for physical in missing.intersection(missingPhysicalKeys) { releaseKey(physical) }
        missingPhysicalKeys = missing.intersection(physicalKeys.keys)
        let modifiers = ModifierSides.released(from: heldModifierVKs, in: currentModifierFlags(),
                                               includeCommand: forwardsCommand)
        let released = modifiers.intersection(missingModifierVKs)
        for vk in released.sorted() { sendModifier(vk, down: false, modByte: 0) }
        heldModifierVKs.subtract(released)
        missingModifierVKs = modifiers.intersection(heldModifierVKs)
    }

    func updateReconciliationTimer() {
        inputCore.lock.lock(); defer { inputCore.lock.unlock() }
        let active = !physicalKeys.isEmpty || !heldModifierVKs.isEmpty || !heldMouseButtons.isEmpty
            || !releases.pending.isEmpty || !releases.held.isEmpty
            || controllerMouseStates.values.contains(where: { $0.isMouse })
        guard active else {
            inputCore.activityPublished = false
            reconciliationTimer?.invalidate()
            reconciliationTimer = nil
            return
        }
        guard reconciliationTimer == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reconcilePhysicalInputs()
                self?.reconcileControllerButtons()
            }
        }
        reconciliationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func reconcileControllerButtons() {
        inputCore.lock.lock(); defer { inputCore.lock.unlock() }
        let timing = InputTimingContext.suspend(); defer { timing?.restore() }
        publishInputSnapshot()
        guard forwardsControllerEvents else { return }
        for state in attachedControllers.values {
            guard let pad = state.controller?.extendedGamepad else { continue }
            let buttons = pressedButtonFlags(pad: pad)
            let analog = Self.controllerAnalog(pad)
            guard controllerNeedsRelease(slot: state.slot, buttons: buttons,
                                         leftDown: analog.leftTrigger > 0, rightDown: analog.rightTrigger > 0)
                || inputCore.mouseNeedsUpdate(slot: state.slot, buttons: buttons, analog: analog) else { continue }
            sendGamepadUpdate(pad: pad, slot: state.slot)
        }
        for state in attachedHIDControllers.values {
            let current = state.device.state
            if controllerNeedsRelease(slot: state.slot, buttons: current.buttons,
                                      leftDown: current.analog.leftTrigger > 0,
                                      rightDown: current.analog.rightTrigger > 0)
                || inputCore.mouseNeedsUpdate(slot: state.slot, buttons: current.buttons, analog: current.analog) {
                pushHID(state.device)
            }
        }
    }

    func inputOwnershipLost(reason: String, includingControllers: Bool = true) {
        inputCore.lock.lock(); defer { inputCore.lock.unlock() }
        inputGeneration &+= 1
        raiseAllHeldInputs(reason: reason)
        if includingControllers || !isMiniPlayer {
            neutralizeControllers()
            cancelQuitChordDwell(reason: reason)
        }
        cancelEscapeHold()
    }

    func installInputRecoveryObservers() {
        removeInputRecoveryObservers()
        let notifications: [(NotificationCenter, Notification.Name, Bool)] = [
            (.default, NSApplication.didResignActiveNotification, false),
            (.default, NSApplication.didBecomeActiveNotification, true),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.willSleepNotification, false),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.screensDidSleepNotification, false),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification, true),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.screensDidWakeNotification, true)
        ]
        for (center, name, recovered) in notifications {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if recovered {
                        self?.reconcilePhysicalInputs()
                        self?.resyncControllers()
                    } else {
                        self?.inputOwnershipLost(
                            reason: "app inactive or sleeping",
                            includingControllers: name != NSApplication.didResignActiveNotification)
                    }
                }
            }
            inputRecoveryObservers.append((center, token))
        }
    }

    func removeInputRecoveryObservers() {
        for (center, token) in inputRecoveryObservers { center.removeObserver(token) }
        inputRecoveryObservers.removeAll()
    }
}
