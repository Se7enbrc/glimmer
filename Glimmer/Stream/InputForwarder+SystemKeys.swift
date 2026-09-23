//
//  InputForwarder+SystemKeys.swift
//
//  "Send ⌘ to the PC as the Windows key": while the stream holds the pointer, the
//  Mac's global hotkeys are off and ⌘ key equivalents go to the PC, the way
//  SDL's keyboard grab works for moonlight.
//

import AppKit

extension InputForwarder {

    /// ⌘ is the PC's Win key only while ⌘ shortcuts belong to the game and the
    /// stream holds the pointer, the same window the global hotkeys are off for.
    /// Otherwise ⌘ stays the Mac's, so a ⌘-Tab or ⌘V never leaves a lone Win tap.
    var forwardsCommand: Bool { captureSysKeys && isMouseCaptured }

    /// A ⌘ key equivalent, offered before the main menu sees it. Claimed and
    /// forwarded to the PC only while ⌘ is.
    func streamView(_ view: StreamInputView, handleKeyEquivalent event: NSEvent) -> Bool {
        guard forwardsCommand, event.modifierFlags.contains(.command) else { return false }
        return streamView(view, handleKeyDown: event)
    }

    /// Capture ended with ⌘ down: ⌘ is the Mac's again, so the PC's Win key is
    /// let go here, and nothing later (a paste, a modifier change) finds it held.
    func releaseCommandSides() {
        let sides = heldModifierVKs.intersection([0x5B, 0x5C]) // VK_LWIN, VK_RWIN
        guard !sides.isEmpty else { return }
        heldModifierVKs.subtract(sides)
        guard isReady else { return }
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

    /// Off while the game holds the pointer, back on when it lets go (capture
    /// exits on resign-key and at teardown). Repeats are free.
    static func setDisabled(_ disabled: Bool) {
        guard disabled != isDisabled, let calls else { return }
        isDisabled = disabled
        // CGSGlobalHotKeyDisable = 1, CGSGlobalHotKeyEnable = 0.
        _ = calls.setMode(calls.connection(), disabled ? 1 : 0)
    }
}
