// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AppKit

struct InputReleaseLedger {
    enum Release: Hashable {
        case key(VKScanCode)
        case mouse(Int32)
        case controller(UInt8)
    }

    var held: Set<Release> = []
    var pending: [Release] = []
    var keyReleaseModifiers: [VKScanCode: Int8] = [:]
    var controllerRemovals: Set<UInt8> = []
    var flushCount = 0
    var reconciledCount = 0
    var lastNoticeTime: TimeInterval = 0
    // Accepted releases may still be unacknowledged when a connection closes.
    private var connectionInputs: [Release] = []

    mutating func hold(_ input: Release) {
        held.insert(input)
        remember(input)
    }

    mutating func remember(_ input: Release) {
        if !connectionInputs.contains(input) { connectionInputs.append(input) }
    }

    mutating func release(_ input: Release, modifiers: Int8 = 0) {
        guard held.contains(input), !pending.contains(input) else { return }
        pending.append(input)
        if case .key(let key) = input { keyReleaseModifiers[key] = modifiers }
    }

    mutating func releaseAll(connectionLost: Bool = false) {
        if connectionLost {
            held.formUnion(connectionInputs)
            keyReleaseModifiers.removeAll()
        }
        for input in connectionInputs { release(input) }
        if connectionLost {
            // A replacement announces pads before its live-state resync, never an old neutral frame.
            held = held.filter { if case .controller = $0 { return false }; return true }
            pending.removeAll { if case .controller = $0 { return true }; return false }
            controllerRemovals.removeAll()
            connectionInputs.removeAll()
        }
    }

    mutating func releaseKeyboardAndMouse() {
        for input in connectionInputs {
            if case .controller = input { continue }
            release(input)
        }
    }

    mutating func accepted(_ input: Release) {
        held.remove(input)
        if case .key(let key) = input { keyReleaseModifiers[key] = nil }
        if case .controller(let slot) = input { controllerRemovals.remove(slot) }
        pending.removeAll { $0 == input }
    }
}

extension InputForwarder {
    var ownsKeyboard: Bool {
        guard let window else { return true }
        return window.isKeyWindow && window.firstResponder === inputView
    }

    /// A failed release is a barrier: later presses cannot overtake it.
    @discardableResult
    func flushPendingReleases() -> Bool {
        inputCore.lock.lock(); defer { inputCore.lock.unlock() }
        guard inputCore.flushReleases() else { updateReconciliationTimer(); return false }
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
        releases.release(.mouse(button))
        flushPendingReleases()
    }

    /// Physical ownership ends now; offline release obligations survive until channel acceptance.
    func raiseAllHeldInputs(reason: String) {
        inputCore.lock.lock(); defer { inputCore.lock.unlock() }
        releases.releaseKeyboardAndMouse()
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

    /// During a client chord only releases from the last accepted frame may pass.
    func releaseSuppressedControllerButtons(slot: UInt8, buttons: Int32, leftDown: Bool, rightDown: Bool) {
        guard controllerNeedsRelease(slot: slot, buttons: buttons, leftDown: leftDown, rightDown: rightDown) else {
            return
        }
        sendControllerState(slot: slot, buttons: (controllerButtons[slot] ?? 0) & buttons,
                            analog: Self.neutralControllerAnalog)
    }

    func controllerNeedsRelease(slot: UInt8, buttons: Int32, leftDown: Bool, rightDown: Bool) -> Bool {
        inputCore.withLock {
            inputCore.needsRelease(slot: slot, buttons: buttons, leftDown: leftDown, rightDown: rightDown)
        }
    }
}
