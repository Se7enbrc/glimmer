// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AppKit
import SwiftUI

enum PairingPresentationOwner {
    case launcher, settings
}

extension EnvironmentValues {
    @Entry var pairingOwner: PairingPresentationOwner = .launcher
}

extension AppModel {
    /// Keep the owner through success and dismissal, after the network attempt has ended.
    func requestPairing(for host: Host?, owner: PairingPresentationOwner = .launcher) {
        guard pairSheetOwner == nil else {
            pairSheetWindow?.sheetParent?.makeKeyAndOrderFront(nil)
            pairSheetWindow?.makeKeyAndOrderFront(nil)
            return
        }
        pairSheetOwner = owner
        pairSheetHost = host
        pairSheetWindow = NSApp?.keyWindow
        pairSheetShown = true
    }

    func finishPairingPresentation(owner: PairingPresentationOwner) {
        guard pairSheetOwner == owner else { return }
        pairSheetShown = false
        pairSheetOwner = nil
        pairSheetHost = nil
        pairSheetWindow = nil
    }
}

struct PairingPresentation: ViewModifier {
    let owner: PairingPresentationOwner
    @Environment(AppModel.self) private var model

    private func finish() { model.finishPairingPresentation(owner: owner) }

    func body(content: Content) -> some View {
        content
            .environment(\.pairingOwner, owner)
            .sheet(isPresented: Binding(
                get: { model.pairSheetShown && model.pairSheetOwner == owner },
                set: { if model.pairSheetOwner == owner { model.pairSheetShown = $0 } }
            ), onDismiss: finish) {
                if owner == .settings, model.pairSheetHost == nil {
                    PairSheet(repairing: model.pairSheetHost).environment(model)
                        .presentationBackground(.thinMaterial)
                } else {
                    PairSheet(repairing: model.pairSheetHost).environment(model)
                }
            }
    }
}
