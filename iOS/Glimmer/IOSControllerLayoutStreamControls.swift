// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import SwiftUI

struct IOSControllerLayoutStreamButton: View {
    let model: StreamSessionModel
    @State private var presented = false

    var body: some View {
        Button("Controller layouts", systemImage: "gamecontroller") {
            model.showControls()
            presented = true
        }
        .sheet(isPresented: $presented) {
            NavigationStack {
                ControllerLayoutsView(initialScope: .game(pcID: model.launch.pcID,
                    appID: UInt32(clamping: model.launch.appID)))
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { presented = false } }
                    }
            }
        }
    }
}
