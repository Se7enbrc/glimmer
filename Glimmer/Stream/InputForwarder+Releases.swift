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
        remember(input)
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
        guard isReady else { return releases.pending.isEmpty }
        let count = releases.pending.count
        while let release = releases.pending.first {
            let result = sendRelease(release)
            record("input release", result)
            guard result == 0 else { updateReconciliationTimer(); return false }
            releases.accepted(release)
            if case .controller(let slot) = release {
                controllerButtons[slot] = 0
                controllerAnalogs[slot] = Self.neutralControllerAnalog
            }
        }
        if count > 0 { releases.flushCount += 1; reportReleaseRecovery() }
        if controllersNeedAnnouncement {
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

    private func sendRelease(_ release: InputReleaseLedger.Release) -> Int32 {
        switch release {
        case .key(let key):
            return backend?.sendKeyboard(keyCode: key.wireCode, action: Int8(StreamProtocol.KEY_ACTION_UP),
                                         modifiers: releases.keyReleaseModifiers[key] ?? 0, flags: key.flags) ?? -2
        case .mouse(let button):
            return backend?.sendMouseButton(action: Int8(StreamProtocol.BUTTON_ACTION_RELEASE), button: button) ?? -2
        case .controller(let slot):
            let mask = releases.controllerRemovals.contains(slot) ? gamepadMask & ~(1 << slot) : gamepadMask
            return backend?.sendMultiController(num: Int16(slot), mask: Int16(bitPattern: mask),
                                                 buttons: 0, analog: Self.neutralControllerAnalog) ?? -2
        }
    }

    func releaseKey(_ physical: UInt16, modifiers: Int8 = 0) {
        guard let key = physicalKeys.removeValue(forKey: physical) else { return }
        heldKeys.remove(key)
        releases.release(.key(key), modifiers: modifiers)
        flushPendingReleases()
    }

    func releaseMouse(_ button: Int32) {
        heldMouseButtons.remove(button)
        releases.release(.mouse(button))
        flushPendingReleases()
    }

    /// Physical ownership ends now; offline release obligations survive until channel acceptance.
    func raiseAllHeldInputs(reason: String) {
        releases.releaseKeyboardAndMouse()
        heldKeys.removeAll()
        physicalKeys.removeAll()
        heldMouseButtons.removeAll()
        heldModifierVKs.removeAll()
        modifiersNeedResync = true
        let count = releases.pending.count
        if count > 0 { Diag.notice("input: \(count) pending releases on \(reason)", "Stream") }
        flushPendingReleases()
        updateReconciliationTimer()
    }

    func sendControllerState(slot: UInt8, buttons: Int32, analog: GamepadAnalog) {
        guard isReady, flushPendingReleases() else {
            releases.release(.controller(slot))
            updateReconciliationTimer()
            return
        }
        releases.hold(.controller(slot))
        let result = backend?.sendMultiController(num: Int16(slot), mask: Int16(bitPattern: gamepadMask),
                                                  buttons: buttons, analog: analog) ?? -2
        record("LiSendMultiControllerEvent", result)
        if result == 0 {
            controllerButtons[slot] = buttons
            controllerAnalogs[slot] = analog
            if buttons == 0 && analog == Self.neutralControllerAnalog { releases.accepted(.controller(slot)) }
        } else {
            releases.release(.controller(slot))
        }
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
        let analog = controllerAnalogs[slot] ?? Self.neutralControllerAnalog
        return (controllerButtons[slot] ?? 0) & ~buttons != 0
            || (analog.leftTrigger > 0 && !leftDown) || (analog.rightTrigger > 0 && !rightDown)
    }
}
