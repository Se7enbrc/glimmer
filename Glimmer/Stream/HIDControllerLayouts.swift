// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import GlimmerEngine
import Synchronization

@MainActor
enum HIDControllerLayouts {
    static func identity(_ pad: HIDGamepadDevice) -> ControllerLayoutIdentity {
        let repeatedSerial = HIDGamepadManager.shared.devices.values.contains {
            $0.id != pad.id && $0.vendor == pad.vendor && $0.product == pad.product && $0.serialNumber == pad.serialNumber
        }
        let defaults = PersistentStorage.defaults
        let saltKey = "controllerLayoutIdentitySalt"
        let salt = defaults.data(forKey: saltKey) ?? Data(UUID().uuidString.utf8)
        if defaults.data(forKey: saltKey) == nil { defaults.set(salt, forKey: saltKey) }
        return .init(category: "hid:\(pad.vendor):\(pad.product)", profile: "normalized",
            controls: controls(pad).map { $0.id.identityName }, vendor: pad.vendor, product: pad.product,
            verifiedSerial: repeatedSerial ? nil : pad.serialNumber, salt: salt)
    }

    static func controls(_ pad: HIDGamepadDevice) -> [ControllerLayoutControl] {
        var sources = ControllerMappedButton.allCases.filter { pad.mapping.supportedButtons & $0.rawValue != 0 }
            .map { ControllerLayoutSource.button($0) }
        let analogs: [(String, ControllerLayoutSource)] = [
            ("lefttrigger", .trigger(.left)), ("righttrigger", .trigger(.right)),
            ("leftx", .axis(.leftX)), ("lefty", .axis(.leftY)), ("rightx", .axis(.rightX)), ("righty", .axis(.rightY))
        ]
        for (name, source) in analogs where pad.mapping.bindings[name] != nil {
            sources.append(source)
            if case .axis(let axis) = source {
                sources += [.direction(axis, positive: false), .direction(axis, positive: true)]
            }
        }
        var controls = sources.map { ControllerLayoutControl(id: $0, name: $0.layoutName, symbol: $0.layoutSymbol) }
        controls += pad.layoutExtras.enumerated().map { index, extra in
            .init(id: .extra(extra.name), name: "Extra button \(index + 1)", symbol: "button.horizontal")
        }
        return controls
    }

    static func device(_ pad: HIDGamepadDevice) -> ControllerLayoutDevice {
        let identity = identity(pad)
        let controls = controls(pad)
        let indexes = pad.layoutExtras.map(\.index)
        let capture = pad.capture
        let source = ControllerLayoutCaptureSource(controls: controls, extras: pad.layoutExtras.map(\.name),
            read: { capture.layoutSample(indexes: indexes) }, acquire: { receive in
                let valid = Mutex(true)
                let restore = capture.acquireLayout(indexes: indexes) { sample, now in
                    valid.withLock { if $0 { receive(sample, now) } }
                }
                return { valid.withLock { $0 = false }; restore() }
            })
        return ControllerLayoutDevice(id: "hid:\(pad.id)", name: pad.name, identity: identity,
            owner: identity.hardware.map { .hardware($0) } ?? .type(identity.type), reader: nil, controller: nil,
            controls: controls, nintendoLabels: NintendoControllerType.identify(pad) != nil
                && PersistentStorage.defaults.bool(forKey: "nintendoButtonLayout"), hidID: pad.id, captureSource: source,
            savedCategory: pad.mapping.isHeuristic ? nil : pad.mapping.name)
    }
}
