// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// A free pointer in a window keeps Mac shortcuts local. Fullscreen can forward them.

import AppKit

extension InputForwarder {

    var forwardsCommand: Bool {
        captureSysKeys && window?.isKeyWindow == true && (!isWindowMode || isMouseCaptured)
    }

    func updateSystemKeyCapture(setDisabled: @MainActor (Bool) -> Void = GlobalHotKeys.setDisabled) {
        setDisabled(forwardsCommand)
        if !forwardsCommand { releaseCommandSides() }
    }

    /// A ⌘ key equivalent, offered before the main menu sees it. Claimed and
    /// forwarded to the PC only while ⌘ is.
    func streamView(_ view: StreamInputView, handleKeyEquivalent event: NSEvent) -> Bool {
        if consumeStopShortcut(event) { return true }
        if view.hasMarkedText(), !event.modifierFlags.isDisjoint(with: [.command, .control]) {
            view.cancelComposition()
        }
        guard forwardsCommand, event.modifierFlags.contains(.command) else { return false }
        streamView(view, handleKeyDown: event)
        return true
    }

    /// Focus ended with ⌘ down: ⌘ is the Mac's again, so the PC's Win key is
    /// let go here, and nothing later (a paste, a modifier change) finds it held.
    func releaseCommandSides() {
        let sides = heldModifierVKs.intersection([0x5B, 0x5C]) // VK_LWIN, VK_RWIN
        guard !sides.isEmpty else { return }
        heldModifierVKs.subtract(sides)
        for vk in sides.sorted() { sendModifier(vk, down: false, modByte: 0) }
    }
}

/// The WindowServer's global hotkeys (⌘-Tab, ⌘-Space, Mission Control). A
/// private CoreGraphics call looked up at run time, as SDL uses it; when it
/// is missing the Mac simply keeps its shortcuts.
@MainActor
enum GlobalHotKeys {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SetOperatingMode = @convention(c) (Int32, Int32) -> Int32

    private static let calls: (connection: MainConnection, setMode: SetOperatingMode)? = {
        let path = "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"
        guard let handle = dlopen(path, RTLD_LAZY),
              let connection = dlsym(handle, "CGSMainConnectionID"),
              let setMode = dlsym(handle, "CGSSetGlobalHotKeyOperatingMode") else { return nil }
        return (unsafeBitCast(connection, to: MainConnection.self),
                unsafeBitCast(setMode, to: SetOperatingMode.self))
    }()

    private static var isDisabled = false

    /// Focus and teardown balance this independently of pointer capture. Repeats are free.
    static func setDisabled(_ disabled: Bool) {
        guard disabled != isDisabled, let calls else { return }
        isDisabled = disabled
        // CGSGlobalHotKeyDisable = 1, CGSGlobalHotKeyEnable = 0.
        _ = calls.setMode(calls.connection(), disabled ? 1 : 0)
    }
}
