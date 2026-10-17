// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import CoreHaptics
import Foundation
import GameController
import GlimmerEngine

/// Native engine/player calls run only on the shared actuator's serial queue.
final class NativeControllerMotor: @unchecked Sendable {
    let engine: CHHapticEngine
    let player: CHHapticPatternPlayer

    init(engine: CHHapticEngine, player: CHHapticPatternPlayer) {
        self.engine = engine
        self.player = player
    }

    static func make(engine: CHHapticEngine, sharpness: Float, intensity: Float,
                     invalidated: @escaping @Sendable (String) -> Void) throws -> ControllerMotor {
        engine.stoppedHandler = { invalidated("engine stopped (reason \($0.rawValue))") }
        engine.resetHandler = { invalidated("engine reset") }
        do {
            try engine.start()
            let event = CHHapticEvent(eventType: .hapticContinuous,
                parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                             CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)],
                relativeTime: 0, duration: TimeInterval(GCHapticDurationInfinite))
            let player = try engine.makePlayer(with: CHHapticPattern(events: [event], parameters: []))
            let native = NativeControllerMotor(engine: engine, player: player)
            try native.update(intensity)
            try player.start(atTime: CHHapticTimeImmediate)
            return ControllerMotor(updateIntensity: { try native.update($0) }, stop: { native.stop() })
        } catch {
            engine.stop(completionHandler: nil)
            throw error
        }
    }

    private func update(_ value: Float) throws {
        try player.sendParameters([CHHapticDynamicParameter(parameterID: .hapticIntensityControl,
            value: value, relativeTime: 0)], atTime: CHHapticTimeImmediate)
    }

    private func stop() {
        try? update(0)
        try? player.stop(atTime: CHHapticTimeImmediate)
        engine.stop(completionHandler: nil)
    }
}

/// Adapter for existing Mac callers of the scalar shared player-indicator mapping.
enum PlayerLEDs {
    static func playerIndex(solidMask: UInt8) -> GCControllerPlayerIndex {
        GCControllerPlayerIndex(rawValue: ControllerPlayerIndicator.index(solidMask: solidMask)) ?? .indexUnset
    }
}
