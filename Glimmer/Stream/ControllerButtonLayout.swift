// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import GameController

struct NintendoControllerType: Identifiable, Hashable {
    let id: String
    let name: String
    var defaultsKey: String { "nintendoButtonLayout." + id }

    static func identify(category: String, name: String, bottomSymbol: String? = nil) -> Self? {
        let text = (category + " " + name).lowercased()
        let compact = text.filter { $0.isLetter || $0.isNumber }
        if compact.contains("joycon") {
            let side = text.contains("(l)") || category.hasSuffix("Left") ? "left"
                : text.contains("(r)") || category.hasSuffix("Right") ? "right" : "pair"
            return Self(id: "joycon." + side, name: side == "pair" ? "Joy-Con" : "Joy-Con (\(side.capitalized))")
        }
        if compact.contains("switchpro") {
            return Self(id: "switchpro", name: "Switch Pro Controller")
        }
        guard !text.contains("xbox") else { return nil }
        let families = ["sn30", "sf30", "sfc30", "nes30", "fc30", "snes", "nintendo", "switch"]
        let eightBitDo = ["8bitdopro2", "8bitdolite2", "8bitdolitese", "8bitdomicro", "8bitdon30"]
        let known = (families + eightBitDo).contains(where: compact.contains)
        guard known || bottomSymbol?.hasPrefix("b.") == true else { return nil }
        let typeName = name.isEmpty ? category : name
        let key = typeName.lowercased().filter { $0.isLetter || $0.isNumber }
        return Self(id: key, name: typeName)
    }

    @MainActor static func identify(_ controller: GCController) -> Self? {
        identify(category: controller.productCategory, name: controller.vendorName ?? controller.productCategory,
                 bottomSymbol: controller.extendedGamepad?.buttonA.sfSymbolsName)
    }

    @MainActor static func identify(_ pad: HIDGamepadDevice) -> Self? {
        identify(category: "", name: pad.mapping.isHeuristic ? pad.name : pad.mapping.name)
    }

    func usesLabels(in defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: defaultsKey) }
}

enum ControllerButtonLayout {
    // GameController and SDL's macOS DB both expose position; swap only the outgoing PC buttons.
    static func apply(_ buttons: Int32, useNintendoLabels: Bool) -> Int32 {
        guard useNintendoLabels else { return buttons }
        let pairs = [(StreamProtocol.A_FLAG, StreamProtocol.B_FLAG), (StreamProtocol.X_FLAG, StreamProtocol.Y_FLAG)]
        let faceMask = pairs.reduce(Int32(0)) { $0 | $1.0 | $1.1 }
        return pairs.reduce(buttons & ~faceMask) { result, pair in
            result | (buttons & pair.0 != 0 ? pair.1 : 0) | (buttons & pair.1 != 0 ? pair.0 : 0)
        }
    }
}
