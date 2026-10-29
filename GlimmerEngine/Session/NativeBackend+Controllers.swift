// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// MARK: - NativeBackend battery uplink

extension NativeBackend {
    /// LiSendControllerBatteryEvent preserves gamepad-channel order without stamping user activity.
    /// Sunshine battery reports need only readiness; unlike touch/motion, they have no feature-flag gate.
    package func sendControllerBattery(num: UInt8, state: UInt8, percentage: UInt8) -> Int32 {
        guard let batcher = readyBatcher() else { return Self.inputNotReady }
        return batcher.passThroughReport(
            InputEncoder.controllerBattery(num: num, state: state, percentage: percentage),
            channel: gamepadChannel(Int(num)))
    }
}

// MARK: - NativeBackend motion uplink

extension NativeBackend {
    /// LiSendControllerMotionEvent replaces superseded samples on the pad's sensor channel.
    /// InputStream.c gates both motion and touch with LI_FF_CONTROLLER_TOUCH_EVENTS.
    package func sendControllerMotion(num: UInt8, motionType: UInt8,
                                      x: Float, y: Float, z: Float) -> Int32 {
        guard let batcher = readyBatcher() else { return Self.inputNotReady }
        guard withState({ featureFlags }) & Self.ffControllerTouchEvents != 0 else {
            return StreamProtocol.LI_ERR_UNSUPPORTED
        }
        return batcher.updateMotion(num: num, motionType: motionType, x: x, y: y, z: z)
    }
}
