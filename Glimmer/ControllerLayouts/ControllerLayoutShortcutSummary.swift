// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import SwiftUI

struct ControllerLayoutShortcutSummary: View {
    let model: ControllerLayoutsModel
    let device: ControllerLayoutDevice
    #if os(macOS)
    @AppStorage("controllerQuitChord") private var legacy = "l3r3"
    @AppStorage("customControllerChord") private var legacyCustom = Data()
    #endif

    private var saved: ControllerLayoutShortcuts? {
        if let identity = device.identity { return model.library.shortcuts(for: identity) }
        return model.library.shortcuts.first { $0.owner == device.owner }?.shortcuts
    }

    var body: some View {
        LabeledContent("Stop streaming", value: description)
        if conflicts {
            Text("The default stop shortcut uses Show controls. Choose another stop shortcut for this controller.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var description: String {
        if let saved { return saved.stop.isEmpty ? "Off" : saved.stop.map(\.layoutName).sorted().joined(separator: " + ") }
        if conflicts { return "Unavailable with Show controls" }
        #if os(macOS)
        let chord = ControllerQuitChord(rawValue: legacy) ?? .l3r3
        if chord == .custom { return ControllerButton.describe(custom) }
        return chord.displayName
        #else
        return "Menu + Options + L1 + R1"
        #endif
    }

    private var conflicts: Bool {
        guard saved == nil, model.library.records.contains(where: { $0.key.owner == device.owner }) else { return false }
        #if os(macOS)
        let available = Set(device.controls.map(\.id))
        let chord = try? ControllerPhysicalChord(sources: ControllerLayoutShortcuts.escape(available: available), extras: [])
        let held = heldControllerButtons(buttons: Int32(bitPattern: chord?.buttons ?? 0), leftTrigger: 0, rightTrigger: 0)
        return ControllerChord.satisfied(ControllerQuitChord(rawValue: legacy) ?? .l3r3, custom: custom, held: held)
        #else
        return false
        #endif
    }

    #if os(macOS)
    private var custom: Set<ControllerButton> {
        (try? JSONDecoder().decode(Set<ControllerButton>.self, from: legacyCustom)) ?? []
    }
    #endif
}
