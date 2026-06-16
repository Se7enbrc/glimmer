//
//  KeyboardScanMap.swift
//
//  Flat dispatch table: macOS Carbon kVK_* keyCode → Windows VK_* scancode.
//
//  NSEvent.keyCode is the macOS HID/Carbon scan code (kVK_*). These are
//  positional values that map to physical key positions on a US ANSI keyboard.
//  To get the host to react to "the key in the W position" regardless of the
//  user's actual layout, we translate kVK_* to its corresponding Windows VK
//  and let LiSendKeyboardEvent2's high-bit `0x8000` mark it as positional -
//  the host then skips its layout-correction pass.
//
//  Reference: moonlight-qt/app/streaming/input/keyboard.cpp's
//  SDL_SCANCODE → VK_ switch. macOS kVK_* values come from
//  <Carbon/HIToolbox/Events.h>.
//
//  Returns nil for keys we don't know how to forward.
//

import Carbon.HIToolbox

// Flat positional map: Carbon kVK_* keyCode → Windows VK_* scancode. A data
// table rather than a switch so the lookup is O(1) and reads as the pure
// dispatch table it is (the switch form tripped cyclomatic-complexity /
// function-length lints for what is, semantically, zero branching).
private let carbonToVKScanCode: [Int: Int16] = [
    // Letters
    kVK_ANSI_A: 0x41,
    kVK_ANSI_B: 0x42,
    kVK_ANSI_C: 0x43,
    kVK_ANSI_D: 0x44,
    kVK_ANSI_E: 0x45,
    kVK_ANSI_F: 0x46,
    kVK_ANSI_G: 0x47,
    kVK_ANSI_H: 0x48,
    kVK_ANSI_I: 0x49,
    kVK_ANSI_J: 0x4A,
    kVK_ANSI_K: 0x4B,
    kVK_ANSI_L: 0x4C,
    kVK_ANSI_M: 0x4D,
    kVK_ANSI_N: 0x4E,
    kVK_ANSI_O: 0x4F,
    kVK_ANSI_P: 0x50,
    kVK_ANSI_Q: 0x51,
    kVK_ANSI_R: 0x52,
    kVK_ANSI_S: 0x53,
    kVK_ANSI_T: 0x54,
    kVK_ANSI_U: 0x55,
    kVK_ANSI_V: 0x56,
    kVK_ANSI_W: 0x57,
    kVK_ANSI_X: 0x58,
    kVK_ANSI_Y: 0x59,
    kVK_ANSI_Z: 0x5A,

    // Top-row digits
    kVK_ANSI_0: 0x30,
    kVK_ANSI_1: 0x31,
    kVK_ANSI_2: 0x32,
    kVK_ANSI_3: 0x33,
    kVK_ANSI_4: 0x34,
    kVK_ANSI_5: 0x35,
    kVK_ANSI_6: 0x36,
    kVK_ANSI_7: 0x37,
    kVK_ANSI_8: 0x38,
    kVK_ANSI_9: 0x39,

    // Function keys
    kVK_F1: 0x70,
    kVK_F2: 0x71,
    kVK_F3: 0x72,
    kVK_F4: 0x73,
    kVK_F5: 0x74,
    kVK_F6: 0x75,
    kVK_F7: 0x76,
    kVK_F8: 0x77,
    kVK_F9: 0x78,
    kVK_F10: 0x79,
    kVK_F11: 0x7A,
    kVK_F12: 0x7B,
    kVK_F13: 0x7C,
    kVK_F14: 0x7D,
    kVK_F15: 0x7E,
    kVK_F16: 0x7F,
    kVK_F17: 0x80,
    kVK_F18: 0x81,
    kVK_F19: 0x82,
    kVK_F20: 0x83,

    // Whitespace / control
    kVK_Return: 0x0D,        // VK_RETURN
    kVK_Tab: 0x09,           // VK_TAB
    kVK_Space: 0x20,         // VK_SPACE
    kVK_Delete: 0x08,        // VK_BACK
    kVK_Escape: 0x1B,        // VK_ESCAPE
    kVK_ForwardDelete: 0x2E, // VK_DELETE
    kVK_Home: 0x24,          // VK_HOME
    kVK_End: 0x23,           // VK_END
    kVK_PageUp: 0x21,        // VK_PRIOR
    kVK_PageDown: 0x22,      // VK_NEXT
    kVK_LeftArrow: 0x25,     // VK_LEFT
    kVK_RightArrow: 0x27,    // VK_RIGHT
    kVK_DownArrow: 0x28,     // VK_DOWN
    kVK_UpArrow: 0x26,       // VK_UP
    kVK_Help: 0x2F,          // VK_HELP

    // Punctuation (US ANSI positional)
    kVK_ANSI_Semicolon: 0xBA,    // VK_OEM_1
    kVK_ANSI_Equal: 0xBB,        // VK_OEM_PLUS
    kVK_ANSI_Comma: 0xBC,        // VK_OEM_COMMA
    kVK_ANSI_Minus: 0xBD,        // VK_OEM_MINUS
    kVK_ANSI_Period: 0xBE,       // VK_OEM_PERIOD
    kVK_ANSI_Slash: 0xBF,        // VK_OEM_2
    kVK_ANSI_Grave: 0xC0,        // VK_OEM_3 (`)
    kVK_ANSI_LeftBracket: 0xDB,  // VK_OEM_4
    kVK_ANSI_Backslash: 0xDC,    // VK_OEM_5
    kVK_ANSI_RightBracket: 0xDD, // VK_OEM_6
    kVK_ANSI_Quote: 0xDE,        // VK_OEM_7
    kVK_ISO_Section: 0xE2,       // VK_OEM_102 (NON-US backslash)

    // Numpad
    kVK_ANSI_Keypad0: 0x60,  // VK_NUMPAD0
    kVK_ANSI_Keypad1: 0x61,
    kVK_ANSI_Keypad2: 0x62,
    kVK_ANSI_Keypad3: 0x63,
    kVK_ANSI_Keypad4: 0x64,
    kVK_ANSI_Keypad5: 0x65,
    kVK_ANSI_Keypad6: 0x66,
    kVK_ANSI_Keypad7: 0x67,
    kVK_ANSI_Keypad8: 0x68,
    kVK_ANSI_Keypad9: 0x69,
    kVK_ANSI_KeypadMultiply: 0x6A,
    kVK_ANSI_KeypadPlus: 0x6B,
    kVK_ANSI_KeypadMinus: 0x6D,
    kVK_ANSI_KeypadDecimal: 0x6E,
    kVK_ANSI_KeypadDivide: 0x6F,
    kVK_ANSI_KeypadEnter: 0x0D,  // VK_RETURN
    kVK_ANSI_KeypadEquals: 0xBB,
    kVK_ANSI_KeypadClear: 0x90,  // VK_NUMLOCK (best match - Mac's "Clear" is NumLock's position)

    // Misc
    kVK_CapsLock: 0x14,  // VK_CAPITAL
    kVK_Mute: 0xAD,
    kVK_VolumeUp: 0xAF,
    kVK_VolumeDown: 0xAE
]

func vkScanCode(forCarbonKeyCode kc: Int) -> Int16? {
    carbonToVKScanCode[kc]
}
