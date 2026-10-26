// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AppKit
import SwiftUI

struct LauncherContextMenu<MenuContent: View>: NSViewRepresentable {
    let appID: Int
    @Binding var requestedAppID: Int?
    @ViewBuilder let menu: () -> MenuContent

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        guard requestedAppID == appID else { return }
        // Wait for SwiftUI's update to finish before native menu tracking takes over.
        DispatchQueue.main.async {
            guard requestedAppID == appID, view.window != nil else { return }
            requestedAppID = nil
            NSHostingMenu(rootView: menu()).popUp(positioning: nil,
                                                 at: NSPoint(x: 12, y: view.bounds.maxY - 12), in: view)
        }
    }
}
