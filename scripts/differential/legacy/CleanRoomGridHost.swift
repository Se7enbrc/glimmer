// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AppKit
import SwiftUI
#if canImport(GlimmerEngine)
@testable import GlimmerEngine
#endif
@testable import Glimmer

// Baseline-only adapter for trees whose app row has no focus binding (2026.10.7 and earlier).
// generate.sh injects it instead of GlimmerTests/CleanRoomGridHost.swift; never part of a target.
@MainActor
struct CleanRoomGridHost {
    let view: NSView
    private let window: NSWindow
    private let fixture: FakePCModel

    static func render(apps: [LibraryApp]) -> Self? {
        guard let fixture = try? FakePCModel("cleanroom-grid", sunshine: FakeSunshine.scripted([:])) else { return nil }
        let host = Glimmer.Host(id: "cleanroom-pc", name: "Test PC", customName: nil, localAddress: "192.0.2.25",
                                manualAddress: nil, apps: apps, lastConnected: nil, serverCertPEM: nil,
                                appVersion: nil, macAddress: nil)
        fixture.model.hosts = [host]
        fixture.model.selectedHost = host
        fixture.settle()
        let view = NSHostingView(rootView: Row(apps: apps, host: host).environment(fixture.model))
        view.frame = NSRect(origin: .zero, size: CGSize(width: 532, height: view.fittingSize.height))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        return Self(view: view, window: window, fixture: fixture)
    }

    func close() {
        window.orderOut(nil)
        fixture.remove()
    }

    private struct Row: View {
        let apps: [LibraryApp]
        let host: Glimmer.Host

        var body: some View {
            AppIconsRow(apps: apps, host: host).frame(width: 532)
        }
    }
}
