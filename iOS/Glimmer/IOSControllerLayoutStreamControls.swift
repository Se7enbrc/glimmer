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
        .buttonStyle(.glass)
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

struct IOSControllerLayoutStreamControls: ViewModifier {
    let model: StreamSessionModel

    func body(content: Content) -> some View {
        content.onChange(of: model.inputFocused, initial: true) { [weak model] _, _ in
            model?.streamInput?.observeControllerEscape { [weak model] in
                Task { @MainActor in model?.showControls() }
            }
        }
        .onDisappear { model.streamInput?.observeControllerEscape(nil) }
    }
}
