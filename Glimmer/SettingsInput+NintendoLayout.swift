// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GameController
import SwiftUI

struct NintendoLayoutSettings: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let types = Self.connectedTypes()
            if !types.isEmpty {
                Section("Controller buttons") {
                    ForEach(types) { type in NintendoLayoutToggle(type: type) }
                }
            }
        }
        .onAppear { HIDGamepadManager.shared.retain(reading: false) }
        .onDisappear { HIDGamepadManager.shared.release(reading: false) }
    }

    static func connectedTypes(native: [NintendoControllerType]? = nil,
                               hid: [NintendoControllerType]? = nil) -> [NintendoControllerType] {
        let native = native ?? GCController.controllers().compactMap(NintendoControllerType.identify)
        let hid = hid ?? HIDGamepadManager.shared.devices.values.compactMap(NintendoControllerType.identify)
        let grouped = Dictionary(grouping: native + hid, by: \.id)
        return grouped.values.compactMap(\.first).sorted { $0.name < $1.name }
    }
}

private struct NintendoLayoutToggle: View {
    let type: NintendoControllerType
    @AppStorage private var useLabels: Bool

    init(type: NintendoControllerType) {
        self.type = type
        _useLabels = AppStorage(wrappedValue: false, type.defaultsKey)
    }

    var body: some View {
        Toggle(isOn: $useLabels) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Use Nintendo button layout")
                Text("\(type.name): match A, B, X and Y by their labels. Off matches their positions on the PC.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel("Use Nintendo button layout for \(type.name)")
    }
}
