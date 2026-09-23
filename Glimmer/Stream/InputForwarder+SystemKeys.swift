//
//  InputForwarder+SystemKeys.swift
//
//  "Use ⌘ shortcuts inside the game": while the stream holds the pointer, the
//  Mac's global hotkeys are off and ⌘ key equivalents go to the PC, the way
//  SDL's keyboard grab works for moonlight.
//

import AppKit

extension InputForwarder {

    /// A ⌘ key equivalent, offered before the main menu sees it. Claimed and
    /// forwarded only while ⌘ shortcuts belong to the game and the pointer is
    /// held, the same window the global hotkeys are off for.
    func streamView(_ view: StreamInputView, handleKeyEquivalent event: NSEvent) -> Bool {
        guard captureSysKeys, isMouseCaptured, event.modifierFlags.contains(.command) else { return false }
        return streamView(view, handleKeyDown: event)
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
