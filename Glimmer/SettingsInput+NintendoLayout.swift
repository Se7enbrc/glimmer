// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import GameController
import SwiftUI

@MainActor @Observable
final class NintendoControllerPresence {
    private(set) var isConnected = false
    private var observers: [NSObjectProtocol] = []

    static func connected(native: [NintendoControllerType]? = nil, hid: [NintendoControllerType]? = nil) -> Bool {
        let native = native ?? GCController.controllers().compactMap(NintendoControllerType.identify)
        let hid = hid ?? HIDGamepadManager.shared.devices.values.compactMap(NintendoControllerType.identify)
        return !native.isEmpty || !hid.isEmpty
    }

    func start(connected: @escaping @MainActor () -> Bool = { NintendoControllerPresence.connected() }) {
        guard observers.isEmpty else { return }
        let names: [Notification.Name] = [.GCControllerDidConnect, .GCControllerDidDisconnect,
                                           HIDGamepadManager.devicesDidChange]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isConnected = connected() }
            }
        }
        isConnected = connected()
    }

    func stop() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }
}

struct NintendoLayoutSettings: View {
    let isConnected: Bool
    @AppStorage(ControllerButtonLayout.defaultsKey, store: PersistentStorage.defaults) private var useLabels = false

    var body: some View {
        Group {
            if isConnected {
                Section("Controller buttons") {
                    Toggle(isOn: $useLabels) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Use Nintendo button layout")
                            Text("Match A, B, X and Y by their labels. "
                                + "Off sends each button in the position of an Xbox controller's.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityLabel("Use Nintendo button layout")
                }
            }
        }
    }
}
