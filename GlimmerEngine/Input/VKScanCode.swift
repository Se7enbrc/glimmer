// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

/// One key as the host receives it: the Windows VK plus the keyboard-event
/// flags. An integer literal is a plain VK with no flags.
package struct VKScanCode: Hashable, Sendable {
    package init(vk: Int16, flags: Int8 = 0) {
        self.vk = vk
        self.flags = flags
    }

    /// SS_KBE_FLAG_NON_NORMALIZED: the VK is already in the PC's layout.
    package static let nonNormalized: Int8 = 0x01

    package let vk: Int16
    package var flags: Int8 = 0

    /// The high bit asks the host to skip its layout-correction pass.
    package var wireCode: Int16 { Int16(bitPattern: 0x8000 | UInt16(bitPattern: vk)) }
}

extension VKScanCode: ExpressibleByIntegerLiteral {
    package init(integerLiteral vk: Int16) {
        self.init(vk: vk)
    }
}
