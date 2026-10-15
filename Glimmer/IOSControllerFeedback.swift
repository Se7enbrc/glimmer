// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import CoreHaptics
import GameController
import GlimmerEngine

/// Native device calls are serialized by the shared feedback queue.
final class IOSControllerFeedback: @unchecked Sendable {
    private weak var controller: GCController?
    private let supported: Set<ControllerFeedbackOutput.Locality>
    private let hasLight: Bool
    private let lock = NSLock()
    private var active = true
    private let priorPlayerIndex: GCControllerPlayerIndex

    init(_ controller: GCController) {
        self.controller = controller
        priorPlayerIndex = controller.playerIndex
        let native = controller.haptics?.supportedLocalities ?? []
        supported = Set(Self.localities.filter { native.contains($0.value) }.keys)
        hasLight = controller.light != nil
    }

    func output() -> ControllerFeedbackOutput {
        let makeMotor: ControllerFeedbackOutput.MotorFactory = { [self] locality, sharpness, intensity, invalidated in
            guard let native = Self.localities[locality],
                  let engine = device()?.haptics?.createEngine(withLocality: native) else { return nil }
            engine.stoppedHandler = { invalidated("engine stopped (reason \($0.rawValue))") }
            engine.resetHandler = { invalidated("engine reset") }
            return try IOSControllerMotor.make(calls: IOSNativeHapticEngine(engine).calls(
                sharpness: sharpness, invalidated: invalidated),
                                               intensity: intensity)
        }
        let light: (@Sendable (UInt8, UInt8, UInt8) -> Void)? = hasLight ? setLight : nil
        return ControllerFeedbackOutput(localities: supported, makeMotor: makeMotor,
                                        setLight: light, setPlayerIndex: { [self] in setPlayerIndex($0) })
    }

    private func setLight(red: UInt8, green: UInt8, blue: UInt8) {
        lock.withLock {
            guard active else { return }
            controller?.light?.color = GCColor(red: Float(red) / 255, green: Float(green) / 255,
                                               blue: Float(blue) / 255)
        }
    }

    func invalidate() {
        lock.withLock {
            guard active else { return }
            active = false
            controller?.playerIndex = priorPlayerIndex
        }
    }

    func setPlayerIndex(_ index: Int) -> Bool {
        lock.withLock {
            guard active, let controller, let native = GCControllerPlayerIndex(rawValue: index),
                  controller.playerIndex != native else { return false }
            controller.playerIndex = native
            return true
        }
    }

    private func device() -> GCController? { lock.withLock { active ? controller : nil } }

    private static let localities: [ControllerFeedbackOutput.Locality: GCHapticsLocality] = [
        .leftHandle: .leftHandle, .rightHandle: .rightHandle, .leftTrigger: .leftTrigger,
        .rightTrigger: .rightTrigger, .handles: .handles, .all: .all
    ]
}

enum IOSControllerMotor {
    struct Player: Sendable {
        let update: @Sendable (Float) throws -> Void
        let start: @Sendable () throws -> Void
        let stop: @Sendable () throws -> Void
    }

    struct Calls: Sendable {
        let start: @Sendable () throws -> Void
        let player: @Sendable () throws -> Player
        let stop: @Sendable () -> Void
        var observeCompletion: @Sendable () -> Void = {}
    }

    static func make(calls: Calls, intensity: Float) throws -> ControllerMotor {
        var player: Player?
        do {
            try calls.start()
            let prepared = try calls.player()
            player = prepared
            try prepared.update(intensity)
            try prepared.start()
            calls.observeCompletion()
            return ControllerMotor(updateIntensity: prepared.update, stop: {
                try? prepared.update(0)
                try? prepared.stop()
                calls.stop()
            })
        } catch {
            try? player?.stop()
            calls.stop()
            throw error
        }
    }
}

/// CoreHaptics objects stay on the engine's serialized native-actuation path.
private final class IOSNativeHapticEngine: @unchecked Sendable {
    let engine: CHHapticEngine
    init(_ engine: CHHapticEngine) { self.engine = engine }

    func calls(sharpness: Float, invalidated: @escaping @Sendable (String) -> Void) -> IOSControllerMotor.Calls {
        IOSControllerMotor.Calls(start: { try self.engine.start() }, player: {
            let event = CHHapticEvent(eventType: .hapticContinuous,
                parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                             CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)],
                relativeTime: 0, duration: TimeInterval(GCHapticDurationInfinite))
            let native = IOSNativeHapticPlayer(try self.engine.makePlayer(
                with: CHHapticPattern(events: [event], parameters: [])))
            return IOSControllerMotor.Player(update: native.update, start: native.start, stop: native.stop)
        }, stop: { self.engine.stop(completionHandler: nil) }, observeCompletion: {
            // A player can finish while its engine stays alive; retire the shared motor in either case.
            self.engine.notifyWhenPlayersFinished { error in
                let code = (error as NSError?)?.code ?? 0
                invalidated("player finished (code \(code))")
                return .stopEngine
            }
        })
    }
}

private final class IOSNativeHapticPlayer: @unchecked Sendable {
    let player: CHHapticPatternPlayer
    init(_ player: CHHapticPatternPlayer) { self.player = player }

    func update(_ intensity: Float) throws {
        try player.sendParameters([CHHapticDynamicParameter(parameterID: .hapticIntensityControl,
            value: intensity, relativeTime: 0)], atTime: CHHapticTimeImmediate)
    }
    func start() throws { try player.start(atTime: CHHapticTimeImmediate) }
    func stop() throws { try player.stop(atTime: CHHapticTimeImmediate) }
}
