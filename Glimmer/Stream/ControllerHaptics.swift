// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AppKit
import Foundation
import GameController
import GlimmerEngine

extension ControllerHaptics {
    static var shared: ControllerHaptics { MacControllerHaptics.shared.engine }

    func register(slot: UInt8, controller: GCController) {
        register(slot: slot, output: MacControllerFeedback(controller).output())
    }
}

/// Mac activation/background ownership and HID side-channel delivery remain native adapter responsibilities.
private final class MacControllerHaptics: @unchecked Sendable {
    static let shared = MacControllerHaptics()
    let engine: ControllerHaptics
    private var observers: [NSObjectProtocol] = []

    private init() {
        var platform = ControllerHaptics.Platform()
        platform.appActive = { NSApplication.shared.isActive }
        platform.stopHID = { DispatchQueue.main.async { HIDGamepadManager.shared.stopRumble() } }
        platform.rumbleHID = { rumble, times in
            DispatchQueue.main.async { HIDGamepadManager.shared.enqueueRumble(rumble, submittedAt: times) }
        }
        engine = ControllerHaptics(platform: platform)
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSApplication.willResignActiveNotification, object: nil, queue: nil) { [weak engine] _ in
                engine?.setSuspended(true)
            },
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak engine] _ in
                engine?.setSuspended(false)
            }
        ]
    }
}

/// The weak controller is accessed only through Apple's thread-safe device actuation properties.
final class MacControllerFeedback: @unchecked Sendable {
    private weak var controller: GCController?
    init(_ controller: GCController) { self.controller = controller }

    func output() -> ControllerFeedbackOutput {
        let supported = controller?.haptics?.supportedLocalities ?? []
        let localities = Set(Self.localities.filter { supported.contains($0.value) }.keys)
        let light: (@Sendable (UInt8, UInt8, UInt8) -> Void)?
        if controller?.light != nil {
            light = { [self] red, green, blue in
                controller?.light?.color = GCColor(red: Float(red) / 255, green: Float(green) / 255,
                                                   blue: Float(blue) / 255)
            }
        } else { light = nil }
        var output = ControllerFeedbackOutput(localities: localities,
            makeMotor: { [self] locality, sharpness, intensity, invalidated in
                guard let native = Self.localities[locality],
                      let engine = controller?.haptics?.createEngine(withLocality: native) else { return nil }
                return try NativeControllerMotor.make(engine: engine, sharpness: sharpness,
                    intensity: intensity, invalidated: invalidated)
            }, setLight: light, setPlayerIndex: { [self] index in
                guard let controller, let value = GCControllerPlayerIndex(rawValue: index),
                      controller.playerIndex != value else { return false }
                controller.playerIndex = value
                return true
            })
        output.mirrorRumble = { [self] low, high in
            guard let device = hidDevice else { return }
            DualSenseHID.shared.setRumbleState(device: device, left: UInt8(low >> 8), right: UInt8(high >> 8))
        }
        output.mirrorLight = { [self] red, green, blue in
            guard let device = hidDevice else { return }
            DualSenseHID.shared.setLightbarState(device: device, red: red, green: green, blue: blue)
        }
        return output
    }

    private var hidDevice: DualSenseDeviceKey? {
        guard let controller, controller.extendedGamepad is GCDualSenseGamepad,
              DualSenseHID.shared.isActive else { return nil }
        return DualSenseRouting.shared.device(for: ObjectIdentifier(controller))
    }

    static let localities: [ControllerFeedbackOutput.Locality: GCHapticsLocality] = [
        .leftHandle: .leftHandle, .rightHandle: .rightHandle, .leftTrigger: .leftTrigger,
        .rightTrigger: .rightTrigger, .handles: .handles, .all: .all
    ]
}
