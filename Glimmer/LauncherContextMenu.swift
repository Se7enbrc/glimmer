// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AppKit
import SwiftUI

struct NativeControllerMenu<MenuContent: View>: NSViewRepresentable {
    @Binding var presented: Bool
    @ViewBuilder let menu: () -> MenuContent
    @Environment(\.streamControlsScale) private var scale

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        guard presented else { return }
        // Wait for SwiftUI's update to finish before native menu tracking takes over.
        DispatchQueue.main.async {
            guard presented, view.window != nil else { return }
            presented = false
            let nativeMenu = NSHostingMenu(rootView: menu())
            if let scale { nativeMenu.font = .systemFont(ofSize: NSFont.preferredFont(forTextStyle: .title3).pointSize * scale) }
            nativeMenu.popUp(positioning: nil, at: NSPoint(x: 12, y: view.bounds.maxY - 12), in: view)
        }
    }
}
