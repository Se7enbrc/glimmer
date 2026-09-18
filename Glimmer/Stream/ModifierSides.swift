//
//  ModifierSides.swift
//
//  Which modifier SIDES a flagsChanged event says are held, as Win VK codes.
//  Pure; the forwarder diffs consecutive answers to emit exact transitions.
//

import AppKit

enum ModifierSides {
    private struct Side {
        let deviceBit: UInt          // AppKit device-dependent flag bit (IOKit NX_DEVICE*KEYMASK)
        let flag: NSEvent.ModifierFlags
        let vk: Int16                // the Win VK for this side
        var isCommand: Bool { flag == .command }
    }

    /// Left side listed first per flag: it is the fallback for a synthetic event.
    private static let sides: [Side] = [
        Side(deviceBit: 0x0001, flag: .control, vk: 0xA2), // VK_LCONTROL
        Side(deviceBit: 0x2000, flag: .control, vk: 0xA3), // VK_RCONTROL
        Side(deviceBit: 0x0002, flag: .shift, vk: 0xA0),   // VK_LSHIFT
        Side(deviceBit: 0x0004, flag: .shift, vk: 0xA1),   // VK_RSHIFT
        Side(deviceBit: 0x0020, flag: .option, vk: 0xA4),  // VK_LMENU
        Side(deviceBit: 0x0040, flag: .option, vk: 0xA5),  // VK_RMENU
        Side(deviceBit: 0x0008, flag: .command, vk: 0x5B), // VK_LWIN
        Side(deviceBit: 0x0010, flag: .command, vk: 0x5C)  // VK_RWIN
    ]

    /// The held sides. A synthetic event (sticky keys) may carry a modifier
    /// flag with no side bit; that counts as the left side so nothing is lost.
    static func held(in flags: NSEvent.ModifierFlags, includeCommand: Bool) -> Set<Int16> {
        let raw = flags.rawValue
        var result = Set<Int16>()
        for side in sides where flags.contains(side.flag) && (includeCommand || !side.isCommand) {
            let anySideBit = sides.contains { $0.flag == side.flag && raw & $0.deviceBit != 0 }
            let isLeft = sides.first { $0.flag == side.flag }?.deviceBit == side.deviceBit
            if raw & side.deviceBit != 0 || (!anySideBit && isLeft) {
                result.insert(side.vk)
            }
        }
        return result
    }
}
