// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

#if DEBUG
import GameController
import Foundation

// Snapshot profiles have no hardware timestamp; callback delivery supplies the same uptime clock as a live profile.
final class JourneyTimestampGamepad: GCExtendedGamepad {
    private let base: GCExtendedGamepad
    init(base: GCExtendedGamepad) { self.base = base; super.init() }
    override var lastEventTimestamp: TimeInterval { ProcessInfo.processInfo.systemUptime }
    override var buttonA: GCControllerButtonInput { base.buttonA }
    override var buttonB: GCControllerButtonInput { base.buttonB }
    override var buttonX: GCControllerButtonInput { base.buttonX }
    override var buttonY: GCControllerButtonInput { base.buttonY }
    override var leftShoulder: GCControllerButtonInput { base.leftShoulder }
    override var rightShoulder: GCControllerButtonInput { base.rightShoulder }
    override var leftTrigger: GCControllerButtonInput { base.leftTrigger }
    override var rightTrigger: GCControllerButtonInput { base.rightTrigger }
    override var leftThumbstickButton: GCControllerButtonInput? { base.leftThumbstickButton }
    override var rightThumbstickButton: GCControllerButtonInput? { base.rightThumbstickButton }
    override var buttonMenu: GCControllerButtonInput { base.buttonMenu }
    override var buttonOptions: GCControllerButtonInput? { base.buttonOptions }
    override var buttonHome: GCControllerButtonInput? { base.buttonHome }
    override var leftThumbstick: GCControllerDirectionPad { base.leftThumbstick }
    override var rightThumbstick: GCControllerDirectionPad { base.rightThumbstick }
    override var dpad: GCControllerDirectionPad { base.dpad }
    override var buttons: [String: GCControllerButtonInput] { base.buttons }
    override var dpads: [String: GCControllerDirectionPad] { base.dpads }
}
#endif
