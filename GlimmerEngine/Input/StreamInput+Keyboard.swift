// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

extension StreamInput {
    public func setKey(hidUsage: UInt16, pressed: Bool, modifiers: UInt8, capturedAt: TimeInterval) {
        InputTimingContext.begin(source: .keyboard, timestamp: capturedAt)
        defer { InputTimingContext.end() }
        core.withLock {
            defer { scheduleReconciliation() }
            guard accepts(capturedAt), let key = PhysicalKeyboardMap.key(forHIDUsage: hidUsage) else { return }
            if pressed { core.pressKey(key, modifiers: Int8(bitPattern: modifiers)) } else {
                core.releaseKey(key, modifiers: Int8(bitPattern: modifiers))
                _ = core.flushReleases()
            }
        }
    }

    /// Device removal ends only keyboard/pointer ownership; controller clicks retain their shared ownership.
    public func releaseKeyboardAndPointer() {
        core.withLock {
            core.releases.releaseKeyboardAndMouse(preservingMouse: core.controllerMouseButtons)
            core.heldMouseButtons.removeAll()
            core.resetPointerMotion()
            core.resetScroll()
            _ = core.flushReleases()
            scheduleReconciliation()
        }
    }
}

extension InputCore {
    @discardableResult
    package func pressKey(_ key: VKScanCode, modifiers: Int8) -> Bool {
        withLock {
            guard snapshot.ready, flushReleases(), !releases.held.contains(.key(key)) else { return false }
            releases.hold(.key(key))
            let result = backend?.sendKeyboard(keyCode: key.wireCode, action: Int8(StreamProtocol.KEY_ACTION_DOWN),
                                               modifiers: modifiers, flags: key.flags) ?? -2
            record("LiSendKeyboardEvent2(down)", result)
            return true
        }
    }

    package func releaseKey(_ key: VKScanCode, modifiers: Int8) {
        withLock {
            releases.release(.key(key), modifiers: modifiers)
        }
    }
}
