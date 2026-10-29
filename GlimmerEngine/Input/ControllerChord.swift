// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

package enum ControllerChord {
    package static let dwellSeconds = 0.4
    package static func satisfied(_ chord: ControllerQuitChord,
                                  custom: Set<ControllerButton>,
                                  held: Set<ControllerButton>) -> Bool {
        let required: Set<ControllerButton>
        switch chord {
        case .none:
            return false
        case .startSelectL1R1:
            // Moonlight default: Start (Options ≡ / Xbox Menu) + Select
            // (Create/Share / Xbox View) + both shoulders.
            required = [.options, .create, .l1, .r1]
        case .l1r1:
            required = [.l1, .r1]
        case .l1r1l2r2:
            required = [.l1, .r1, .l2, .r2]
        case .l3r3:
            required = [.l3, .r3]
        case .custom:
            required = custom
        }
        return !required.isEmpty && required.isSubset(of: held)
    }
}

package func heldControllerButtons(buttons: Int32, leftTrigger: UInt8, rightTrigger: UInt8) -> Set<ControllerButton> {
    let mapping: [(Int32, ControllerButton)] = [
        (StreamProtocol.A_FLAG, .faceDown), (StreamProtocol.B_FLAG, .faceRight),
        (StreamProtocol.X_FLAG, .faceLeft), (StreamProtocol.Y_FLAG, .faceUp),
        (StreamProtocol.UP_FLAG, .dpadUp), (StreamProtocol.DOWN_FLAG, .dpadDown),
        (StreamProtocol.LEFT_FLAG, .dpadLeft), (StreamProtocol.RIGHT_FLAG, .dpadRight),
        (StreamProtocol.LB_FLAG, .l1), (StreamProtocol.RB_FLAG, .r1),
        (StreamProtocol.LS_CLK_FLAG, .l3), (StreamProtocol.RS_CLK_FLAG, .r3),
        (StreamProtocol.TOUCHPAD_FLAG, .touchpad), (StreamProtocol.PLAY_FLAG, .options),
        (StreamProtocol.BACK_FLAG, .create), (StreamProtocol.SPECIAL_FLAG, .ps), (StreamProtocol.MISC_FLAG, .mute)
    ]
    var held = Set(mapping.compactMap { buttons & $0.0 != 0 ? $0.1 : nil })
    if leftTrigger >= ControllerInputSample.triggerPressThreshold { held.insert(.l2) }
    if rightTrigger >= ControllerInputSample.triggerPressThreshold { held.insert(.r2) }
    return held
}
