// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AppKit
import CoreGraphics

extension InputForwarder {
    func noteInputEvent(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        defer { lastInputEventTime = now }
        if let lastInputEventTime, now - lastInputEventTime > 0.1 { reconcilePhysicalInputs() }
    }

    func reconcilePhysicalInputs() {
        inputCore.lock.lock(); defer { inputCore.lock.unlock() }
        guard !physicalKeys.isEmpty || !heldModifierVKs.isEmpty || !heldMouseButtons.isEmpty
            || !releases.pending.isEmpty else { return }
        let before = physicalKeys.count + heldModifierVKs.count + heldMouseButtons.count
        for physical in Array(physicalKeys.keys) where !physicalKeyState(physical) { releaseKey(physical) }
        let flags = currentModifierFlags()
        let missing = ModifierSides.released(from: heldModifierVKs, in: flags, includeCommand: forwardsCommand)
        for vk in missing.sorted() { sendModifier(vk, down: false, modByte: 0) }
        heldModifierVKs.subtract(missing)
        let mouse = currentMouseButtons()
        for button in heldMouseButtons where mouse & Self.mouseMask(button) == 0 { releaseMouse(button) }
        let count = before - physicalKeys.count - heldModifierVKs.count - heldMouseButtons.count
        if count > 0 { releases.reconciledCount += count; reportReleaseRecovery() }
        flushPendingReleases()
    }

    private static func mouseMask(_ button: Int32) -> Int {
        // Sunshine numbers left/middle/right as 1/2/3; AppKit uses left/right/middle bits.
        let index = [1: 0, 2: 2, 3: 1, 4: 3, 5: 4][button] ?? 0
        return 1 << index
    }

    func updateReconciliationTimer() {
        inputCore.lock.lock(); defer { inputCore.lock.unlock() }
        let active = !physicalKeys.isEmpty || !heldModifierVKs.isEmpty || !heldMouseButtons.isEmpty
            || !releases.pending.isEmpty || releases.held.contains {
                if case .controller = $0 { return true }
                return false
            }
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
        publishInputSnapshot()
        guard forwardsControllerEvents else { return }
        for state in attachedControllers.values {
            guard let pad = state.controller?.extendedGamepad,
                  controllerNeedsRelease(slot: state.slot, buttons: pressedButtonFlags(pad: pad),
                                         leftDown: pad.leftTrigger.value > 0,
                                         rightDown: pad.rightTrigger.value > 0) else { continue }
            sendGamepadUpdate(pad: pad, slot: state.slot)
        }
        for state in attachedHIDControllers.values {
            let current = state.device.state
            if controllerNeedsRelease(slot: state.slot, buttons: current.buttons,
                                      leftDown: current.analog.leftTrigger > 0,
                                      rightDown: current.analog.rightTrigger > 0) {
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
