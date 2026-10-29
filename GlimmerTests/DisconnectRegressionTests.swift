// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import GlimmerEngine
import AppKit
import SwiftUI
import Testing
@testable import Glimmer

struct DisconnectRegressionTests {
    @MainActor @Test(arguments: [false, true])
    func backToStreamOnlyAppearsInTheBackground(backgrounded: Bool) throws {
        let fixture = try FakePCModel("stream-tile-regression", sunshine: FakeSunshine.scripted([:]))
        defer { fixture.remove() }
        let host = try fixture.pairTower()
        let app = try #require(host.apps.first)
        fixture.model.lastLaunchAttempt = (app, host)
        fixture.model.isStreaming = true
        fixture.model.streamPhase = .streaming
        fixture.model.nativeStreamBackgrounded = backgrounded
        #expect(AppIconsRow.tileState(app, on: host, model: fixture.model, connectingShown: false)
                == (backgrounded ? .hiddenStream : .running))
    }

    @MainActor @Test(arguments: [0, 1, 2, 3, 4, 5, 80])
    func launcherPartitionPreservesEveryAppIdentity(count: Int) {
        let apps = (0..<count).map { LibraryApp(id: $0 + 700, name: "Shared title", hdr: false, hidden: false) }
        let direct = AppIconsRow.inlineApps(apps)
        let menu = AppIconsRow.overflowApps(apps)
        #expect(direct.count == (count <= 4 ? count : 3))
        #expect(menu.count == (count <= 4 ? 0 : count - 3))
        #expect((direct + menu).map(\.id) == apps.map(\.id))
        #expect(Set((direct + menu).map(\.id)).count == count)
    }

    @MainActor @Test func rebuiltLibraryDoesNotKeepPreviousMenuTargets() {
        let large = (0..<9).map { LibraryApp(id: $0 + 200, name: "Library A \($0)", hdr: false, hidden: false) }
        let other = (0..<5).map { LibraryApp(id: $0 + 900, name: "Library B \($0)", hdr: false, hidden: false) }
        #expect(AppIconsRow.overflowApps(large).map(\.id) == Array(203...208))
        #expect(AppIconsRow.overflowApps(other).map(\.id) == [903, 904])
        #expect(AppIconsRow.overflowApps(Array(other.prefix(4))).isEmpty)
    }

    @MainActor @Test(arguments: [false, true], [0, 1, 4, 5, 80])
    func nativeAppRowsKeepBoundedGeometry(dark: Bool, count: Int) throws {
        let fixture = try FakePCModel("overflow-render", sunshine: FakeSunshine.scripted([:]))
        defer { fixture.remove() }
        let apps = (0..<count).map {
            LibraryApp(id: $0 + 300, name: "An independently named adventure with a long title \($0)",
                       hdr: false, hidden: false)
        }
        let host = Glimmer.Host(id: "overflow-pc", name: "Test PC", customName: nil,
                                localAddress: "192.0.2.25", manualAddress: nil, apps: apps,
                                lastConnected: nil, serverCertPEM: nil, appVersion: nil, macAddress: nil)
        fixture.model.hosts = [host]
        fixture.model.selectedHost = host
        fixture.settle()
        let content = OverflowRenderFixture(apps: apps, host: host)
            .environment(fixture.model).preferredColorScheme(dark ? .dark : .light)
        let view = NSHostingView(rootView: content)
        let opening = view.fittingSize
        view.frame = NSRect(origin: .zero, size: opening)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        defer { window.orderOut(nil) }
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        #expect(opening.width == 532)
        #expect(opening.height <= 130)
        if count > 0 {
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            Attachment.record(Array(png), named: "overflow-\(dark ? "dark" : "light")-\(count).png")
        }
        view.frame.size.height += 200
        view.layoutSubtreeIfNeeded()
        #expect(view.fittingSize == opening)
    }

    @Test func stopDoesNotOfferADisconnectOnlyMode() throws {
        #expect(try GlimmerCLI.parse(["stop", "Tower"]) == .init(verb: .stop, arguments: ["Tower"]))
        #expect(throws: GlimmerCLI.UsageError.self) { try GlimmerCLI.parse(["stop", "Tower", "--disconnect"]) }
        #expect(throws: GlimmerCLI.UsageError.self) { try GlimmerCLI.parse(["quit", "Tower", "--force"]) }
    }
}

private struct OverflowRenderFixture: View {
    let apps: [LibraryApp]
    let host: Glimmer.Host
    @FocusState private var focus: LauncherFocus?

    var body: some View {
        AppIconsRow(apps: apps, host: host, focus: $focus)
            .frame(width: 532)
            .fixedSize(horizontal: false, vertical: true)
    }
}
