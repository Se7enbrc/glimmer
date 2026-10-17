// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import AppKit

extension InputForwarder {
    var ownsKeyboard: Bool {
        guard let window else { return true }
        return window.isKeyWindow && window.firstResponder === inputView
    }

    /// A failed release is a barrier: later presses cannot overtake it.
    @discardableResult
    func flushPendingReleases() -> Bool {
        inputCore.lock.lock(); defer { inputCore.lock.unlock() }
        if releases.pending.isEmpty, inputCore.pendingTouchReleases.isEmpty,
           inputCore.pendingArrivals.isEmpty, !controllersNeedAnnouncement, releases.flushCount == 0 { return true }
        guard inputCore.flushReleases(), inputCore.flushControllerArrivals() else { updateReconciliationTimer(); return false }
        if releases.flushCount > 0 { reportReleaseRecovery() }
        if controllersNeedAnnouncement {
            let timing = InputTimingContext.suspend(); defer { timing?.restore() }
            controllersNeedAnnouncement = false
            announceControllers()
            controllersNeedAnnouncement = !releases.pending.isEmpty
        }
        updateReconciliationTimer()
        return releases.pending.isEmpty
    }

    func reportReleaseRecovery() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - releases.lastNoticeTime >= 1 else { return }
        Diag.info("input: \(releases.pending.count) pending releases, \(releases.flushCount) flushes, "
            + "\(releases.reconciledCount) reconciled ups", "Stream")
        releases.lastNoticeTime = now
        releases.flushCount = 0
        releases.reconciledCount = 0
    }

    func releaseKey(_ physical: UInt16, modifiers: Int8 = 0) {
        inputCore.lock.lock(); defer { inputCore.lock.unlock() }
        guard let key = physicalKeys.removeValue(forKey: physical) else { return }
        heldKeys.remove(key)
        missingPhysicalKeys.remove(physical)
        releases.release(.key(key), modifiers: modifiers)
        flushPendingReleases()
    }

    func releaseMouse(_ button: Int32) {
        inputCore.lock.lock(); defer { inputCore.lock.unlock() }
        heldMouseButtons.remove(button)
        physicalMouseButtons = physicalMouseButtons.filter { $0.value != button }
        if !controllerMouseButtons.contains(button) { releases.release(.mouse(button)) }
        flushPendingReleases()
    }

    /// Physical ownership ends now; offline release obligations survive until channel acceptance.
    func raiseAllHeldInputs(reason: String) {
        inputCore.lock.lock(); defer { inputCore.lock.unlock() }
        releases.releaseKeyboardAndMouse(preservingMouse: controllerMouseButtons)
        heldKeys.removeAll()
        physicalKeys.removeAll()
        missingPhysicalKeys.removeAll()
        missingModifierVKs.removeAll()
        physicalMouseButtons.removeAll()
        heldMouseButtons.removeAll()
        heldModifierVKs.removeAll()
        modifiersNeedResync = true
        let count = releases.pending.count
        if count > 0 { Diag.notice("input: \(count) pending releases on \(reason)", "Stream") }
        flushPendingReleases()
        updateReconciliationTimer()
    }

    func sendControllerState(slot: UInt8, buttons: Int32, analog: GamepadAnalog) {
        inputCore.withLock { inputCore.sendController(slot: slot, buttons: buttons, analog: analog) }
        updateReconciliationTimer()
    }

    func controllerNeedsRelease(slot: UInt8, buttons: Int32, leftDown: Bool, rightDown: Bool) -> Bool {
        let mapped = ControllerButtonLayout.apply(
            buttons, useNintendoLabels: useNintendoLabels && nintendoControllerTypes[slot] != nil)
        return inputCore.withLock {
            inputCore.needsRelease(slot: slot, buttons: mapped, leftDown: leftDown, rightDown: rightDown)
        }
    }
}
