// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import SwiftUI
import Testing
import UIKit
@testable import Glimmer

@Suite(.serialized)
@MainActor
struct StreamStatsRenderTests {
    struct Viewport: Sendable {
        let name: String
        let size: CGSize
        let safe: UIEdgeInsets
    }

    nonisolated static let viewports = [
        Viewport(name: "iphone-small", size: CGSize(width: 667, height: 375),
                 safe: UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)),
        Viewport(name: "iphone-large", size: CGSize(width: 956, height: 440),
                 safe: UIEdgeInsets(top: 0, left: 62, bottom: 21, right: 62)),
        Viewport(name: "ipad", size: CGSize(width: 1194, height: 834),
                 safe: UIEdgeInsets(top: 24, left: 0, bottom: 20, right: 0)),
        Viewport(name: "ipad-window", size: CGSize(width: 375, height: 600),
                 safe: UIEdgeInsets(top: 24, left: 0, bottom: 20, right: 0)),
        Viewport(name: "external-display", size: CGSize(width: 1920, height: 1080), safe: .zero)
    ]

    @Test(arguments: viewports, [false, true])
    func overlayBeforeAndAfter(viewport: Viewport, dark: Bool) async throws {
        let scene = try await testWindowScene()
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        let surface = StatsViewport(frame: CGRect(origin: .zero, size: viewport.size))
        surface.insets = viewport.safe
        root.view.addSubview(surface)
        surface.backgroundColor = dark ? UIColor(white: 0.12, alpha: 1) : UIColor(white: 0.92, alpha: 1)
        let overlay = StatsOverlayLayer()
        overlay.displayView = surface
        overlay.attach(to: surface.layer)
        let name = "\(viewport.name)-\(dark ? "dark" : "light")"
        try record(surface, name: "\(name)-before")
        var snapshot = StreamStatsSnapshot()
        snapshot.hostFps = 59.9
        snapshot.renderedFps = 59.9
        snapshot.rttMs = 5.9
        snapshot.measuredBitrateMbps = 45.2
        snapshot.negotiatedBitrateMbps = 50
        snapshot.videoCodec = "HEVC"
        snapshot.receivedFps = 59.9
        snapshot.decodedFps = 59.9
        snapshot.avgDecodeTimeMs = 2.4
        snapshot.jitterMs = 0.09
        snapshot.avgPresentCadenceErrorMs = 0.3
        snapshot.onTimePresentPercent = 99.9
        snapshot.pacingQueueDepth = 1
        overlay.update(snapshot: snapshot, enabled: StatsOverlayDefaults.minimalRows,
                       targetFps: 60)
        overlay.updateBackdropLuminance(dark ? 0.01 : 0.85)
        overlay.setVisible(true)
        overlay.layer.removeAllAnimations()
        let frame = overlay.layer.frame
        #expect(frame.minX >= viewport.safe.left + 16)
        #expect(frame.minY >= viewport.safe.top + 16)
        #expect(frame.maxY <= surface.bounds.height - viewport.safe.bottom)
        try record(surface, name: "\(name)-after")
        #expect(surface.accessibilityValue?.contains("59.9 FPS") == true)
        overlay.update(snapshot: snapshot, enabled: StatsOverlayDefaults.extendedRows, targetFps: 60)
        try record(surface, name: "\(name)-extended-after")
    }

    @Test(arguments: [false, true])
    func inputSettings(dark: Bool) async throws {
        let calls = LauncherModel.Calls(savedPCs: { [] }, prepare: { _, _ in
            throw CancellationError()
        }, pair: { pc, _ in pc }, apps: { _ in [] }, remember: { _ in [] }, protectedDataChanged: { _ in })
        let model = LauncherModel(calls: calls, discoveryEnabled: false)
        let view = NavigationStack {
            GlimmerSettings(profile: .constant(.native120), model: model)
                .settingsPage(.input)
        }
        let scene = try await testWindowScene()
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: view)
        host.overrideUserInterfaceStyle = dark ? .dark : .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        host.view.layoutIfNeeded()
        try record(host.view, name: "settings-\(dark ? "dark" : "light")-after")
    }

    private func record(_ view: UIView, name: String) throws {
        view.layoutIfNeeded()
        CATransaction.flush()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        let data = try #require(image.pngData())
        Attachment.record(Array(data), named: "\(name).png")
    }
}

@MainActor
private final class StatsViewport: UIView {
    var insets = UIEdgeInsets.zero
    override var safeAreaInsets: UIEdgeInsets { insets }
}
