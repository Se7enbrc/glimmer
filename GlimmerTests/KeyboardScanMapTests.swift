//
//  KeyboardScanMapTests.swift
//
//  Known-answer coverage for vkScanCode(forCarbonKeyCode:) (KeyboardScanMap.swift)
//  over the carbonToVKScanCode table: Carbon kVK_* keyCode -> Windows VK_*
//  scancode. A regression here mis-drives the host's keyboard, so we pin a
//  representative span (letters, digits, modifiers, arrows, function keys,
//  numpad, punctuation, ISO, JIS) plus the "unmapped returns nil" contract.
//

import Carbon.HIToolbox
import Testing
@testable import Glimmer

struct KeyboardScanMapTests {

    // MARK: - Letters (kVK_ANSI_A..Z -> 0x41..0x5A)

    @Test func lettersMapToAsciiUppercase() {
        #expect(vkScanCode(forCarbonKeyCode: kVK_ANSI_A) == 0x41)
        #expect(vkScanCode(forCarbonKeyCode: kVK_ANSI_M) == 0x4D)
        #expect(vkScanCode(forCarbonKeyCode: kVK_ANSI_W) == 0x57)
        #expect(vkScanCode(forCarbonKeyCode: kVK_ANSI_Z) == 0x5A)
    }

    // MARK: - Top-row digits (kVK_ANSI_0..9 -> 0x30..0x39)

    @Test func digitsMapToAscii() {
        #expect(vkScanCode(forCarbonKeyCode: kVK_ANSI_0) == 0x30)
        #expect(vkScanCode(forCarbonKeyCode: kVK_ANSI_1) == 0x31)
        #expect(vkScanCode(forCarbonKeyCode: kVK_ANSI_5) == 0x35)
        #expect(vkScanCode(forCarbonKeyCode: kVK_ANSI_9) == 0x39)
    }

    // MARK: - Function keys (kVK_F1.. -> 0x70..)

    @Test func functionKeys() {
        #expect(vkScanCode(forCarbonKeyCode: kVK_F1) == 0x70)
        #expect(vkScanCode(forCarbonKeyCode: kVK_F5) == 0x74)
        #expect(vkScanCode(forCarbonKeyCode: kVK_F12) == 0x7B)
    }

    // MARK: - Whitespace / control

    @Test func whitespaceAndControl() {
        #expect(vkScanCode(forCarbonKeyCode: kVK_Return) == 0x0D)  // VK_RETURN
        #expect(vkScanCode(forCarbonKeyCode: kVK_Tab) == 0x09)     // VK_TAB
        #expect(vkScanCode(forCarbonKeyCode: kVK_Space) == 0x20)   // VK_SPACE
        #expect(vkScanCode(forCarbonKeyCode: kVK_Delete) == 0x08)  // VK_BACK
        #expect(vkScanCode(forCarbonKeyCode: kVK_Escape) == 0x1B)  // VK_ESCAPE
        #expect(vkScanCode(forCarbonKeyCode: kVK_ForwardDelete) == 0x2E) // VK_DELETE
    }

    // MARK: - Navigation / arrows

    @Test func arrowsAndNavigation() {
        #expect(vkScanCode(forCarbonKeyCode: kVK_LeftArrow) == 0x25)   // VK_LEFT
        #expect(vkScanCode(forCarbonKeyCode: kVK_RightArrow) == 0x27)  // VK_RIGHT
        #expect(vkScanCode(forCarbonKeyCode: kVK_DownArrow) == 0x28)   // VK_DOWN
        #expect(vkScanCode(forCarbonKeyCode: kVK_UpArrow) == 0x26)     // VK_UP
        #expect(vkScanCode(forCarbonKeyCode: kVK_Home) == 0x24)        // VK_HOME
        #expect(vkScanCode(forCarbonKeyCode: kVK_End) == 0x23)         // VK_END
        #expect(vkScanCode(forCarbonKeyCode: kVK_PageUp) == 0x21)      // VK_PRIOR
        #expect(vkScanCode(forCarbonKeyCode: kVK_PageDown) == 0x22)    // VK_NEXT
    }

    // MARK: - Modifier-adjacent / lock keys

    @Test func capsLockAndMedia() {
        #expect(vkScanCode(forCarbonKeyCode: kVK_CapsLock) == 0x14)   // VK_CAPITAL
        #expect(vkScanCode(forCarbonKeyCode: kVK_Mute) == 0xAD)
        #expect(vkScanCode(forCarbonKeyCode: kVK_VolumeUp) == 0xAF)
        #expect(vkScanCode(forCarbonKeyCode: kVK_VolumeDown) == 0xAE)
    }

    // MARK: - Punctuation (US ANSI positional VK_OEM_*)

    @Test func punctuation() {
        #expect(vkScanCode(forCarbonKeyCode: kVK_ANSI_Semicolon) == 0xBA)  // VK_OEM_1
        #expect(vkScanCode(forCarbonKeyCode: kVK_ANSI_Equal) == 0xBB)      // VK_OEM_PLUS
        #expect(vkScanCode(forCarbonKeyCode: kVK_ANSI_Comma) == 0xBC)      // VK_OEM_COMMA
        #expect(vkScanCode(forCarbonKeyCode: kVK_ANSI_Minus) == 0xBD)      // VK_OEM_MINUS
        #expect(vkScanCode(forCarbonKeyCode: kVK_ANSI_Slash) == 0xBF)      // VK_OEM_2
    }

    // MARK: - ISO keyboards report the key left of 1 and the one right of left Shift swapped

    @Test func isoKeyboardSwapsSectionAndGrave() {
        #expect(vkScanCode(forCarbonKeyCode: kVK_ANSI_Grave, isISOKeyboard: false) == 0xC0)   // VK_OEM_3
        #expect(vkScanCode(forCarbonKeyCode: kVK_ISO_Section, isISOKeyboard: false) == 0xE2)  // VK_OEM_102
        #expect(vkScanCode(forCarbonKeyCode: kVK_ISO_Section, isISOKeyboard: true) == 0xC0)
        #expect(vkScanCode(forCarbonKeyCode: kVK_ANSI_Grave, isISOKeyboard: true) == 0xE2)
        #expect(vkScanCode(forCarbonKeyCode: kVK_ANSI_A, isISOKeyboard: true) == 0x41)
    }

    // MARK: - PC keyboard keys macOS names differently

    @Test func pcKeyboardKeysReachTheirPCKeys() {
        #expect(vkScanCode(forCarbonKeyCode: kVK_Help) == 0x2D)            // VK_INSERT
        #expect(vkScanCode(forCarbonKeyCode: kVK_ContextualMenu) == 0x5D)  // VK_APPS
        #expect(vkScanCode(forCarbonKeyCode: kVK_F13) == 0x2C)             // VK_SNAPSHOT
        #expect(vkScanCode(forCarbonKeyCode: kVK_F14) == 0x91)             // VK_SCROLL
        #expect(vkScanCode(forCarbonKeyCode: kVK_F15) == 0x13)             // VK_PAUSE
        #expect(vkScanCode(forCarbonKeyCode: kVK_F16) == 0x7F)             // VK_F16
    }

    // MARK: - JIS

    @Test func jisKeys() {
        let yen = VKScanCode(vk: 0xDC, flags: VKScanCode.nonNormalized)
        #expect(vkScanCode(forCarbonKeyCode: kVK_JIS_Yen) == yen)
        #expect(vkScanCode(forCarbonKeyCode: kVK_JIS_Underscore) == VKScanCode(vk: 0xE2, flags: VKScanCode.nonNormalized))
        // ¥ shares VK_OEM_5 with the backslash key yet is a different PC key.
        #expect(vkScanCode(forCarbonKeyCode: kVK_ANSI_Backslash) != yen)
        #expect(vkScanCode(forCarbonKeyCode: kVK_JIS_KeypadComma) == 0x6C)  // VK_SEPARATOR
        #expect(vkScanCode(forCarbonKeyCode: kVK_JIS_Eisu) == 0x1D)         // VK_NONCONVERT
        #expect(vkScanCode(forCarbonKeyCode: kVK_JIS_Kana) == 0x1C)         // VK_CONVERT
    }

    @Test func wireCodeIsMarkedPositional() {
        #expect(VKScanCode(vk: 0x57).wireCode == Int16(bitPattern: 0x8057))
    }

    // MARK: - Numpad

    @Test func numpad() {
        #expect(vkScanCode(forCarbonKeyCode: kVK_ANSI_Keypad0) == 0x60)        // VK_NUMPAD0
        #expect(vkScanCode(forCarbonKeyCode: kVK_ANSI_Keypad9) == 0x69)
        #expect(vkScanCode(forCarbonKeyCode: kVK_ANSI_KeypadPlus) == 0x6B)
        #expect(vkScanCode(forCarbonKeyCode: kVK_ANSI_KeypadDivide) == 0x6F)
        #expect(vkScanCode(forCarbonKeyCode: kVK_ANSI_KeypadEnter) == 0x0D)    // VK_RETURN
    }

    // MARK: - Unmapped codes return nil

    @Test func unmappedReturnsNil() {
        // 0xFFFF is not a valid Carbon keyCode and is absent from the table.
        #expect(vkScanCode(forCarbonKeyCode: 0xFFFF) == nil)
        // -1 is likewise absent.
        #expect(vkScanCode(forCarbonKeyCode: -1) == nil)
    }
}
