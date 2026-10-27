// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import SwiftUI
import Testing
import UIKit
@testable import Glimmer

@Suite(.serialized)
@MainActor
struct StreamMenuRenderTests {
    @Test(arguments: [false, true], [false, true])
    func mobileBoard(dark: Bool, largest: Bool) async throws {
        let tablet = UIDevice.current.userInterfaceIdiom == .pad
        let widths: [CGSize?] = tablet ? [CGSize(width: 1194, height: 834), CGSize(width: 507, height: 834)] : [nil]
        for size in widths {
            for state in ["stats", "menu", "reconnecting"] {
                let fixture = PlaybackFixture()
                fixture.format = StreamFormat(width: 1920, height: 1080, fps: 60)
                let connection = StreamConnection(video: ConnectionTestVideoSink()) { _, _ in }
                let capture = TouchGamepadCapture(input: connection.input)
                #expect(capture.attach())
                let model = StreamSessionModel(launch: testLaunch(), makePlayback: { _, _, _ in
                    StreamPlayback(id: fixture.id, events: fixture.events.stream, start: { nil }, stop: {},
                        screenChanged: {}, focusInput: { capture.setEnabled($0) }, format: fixture.format,
                        observeControllers: { $0(state == "stats") }, touchGamepad: capture)
                })
                let host = StreamViewController(model: model, close: {})
                host.loadViewIfNeeded()
                let picture = UIHostingController(rootView: TouchSampleFrame(exposure: dark ? -0.75 : 0.9)
                    .ignoresSafeArea())
                host.addChild(picture)
                host.view.insertSubview(picture.view, aboveSubview: host.surface)
                picture.didMove(toParent: host)
                picture.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                picture.view.frame = host.view.bounds
                let overlay = StatsOverlayLayer()
                overlay.displayView = host.surface
                overlay.attach(to: picture.view.layer)
                var snapshot = StreamStatsSnapshot()
                snapshot.renderedFps = 59.9
                snapshot.rttMs = 5.9
                snapshot.measuredBitrateMbps = 45.2
                snapshot.videoCodec = "HEVC"
                let name = "mobile-\(size?.width == 507 ? "split" : "full")-\(state)-"
                    + "\(dark ? "dark" : "light")-\(largest ? "AX5" : "normal")"
                try await NativeUIRenderTests().recordController(host, name: name, size: size, dark: dark,
                    prepare: {
                        model.receive(fixture.update(.firstFrame))
                        model.overlayAppearance.update(luminance: dark ? 0.01 : 0.85)
                        if state == "menu" { model.showControls() }
                        if state == "reconnecting" { model.receive(fixture.update(.reconnecting)) }
                        overlay.update(snapshot: snapshot, enabled: StatsOverlayDefaults.minimalRows, targetFps: 60)
                        overlay.updateBackdropLuminance(dark ? 0.01 : 0.85)
                        overlay.setVisible(state == "stats")
                        overlay.layer.removeAllAnimations()
                    }, textSize: largest ? .accessibility5 : .large)
                model.stop()
                await model.waitUntilStopped()
                capture.detach()
                await connection.stop()
            }
        }
    }

    @Test(arguments: [false, true], ["playing", "revealed", "expanded"])
    func menu(dark: Bool, state: String) async throws {
        let fixture = PlaybackFixture()
        fixture.controllerConnected = true
        fixture.format = StreamFormat(width: 1920, height: 1080, fps: 60)
        let clock = WindowResizeClock()
        let menu = StreamMenuVisibility(voiceOver: false, sleep: clock.sleep)
        let model = fixture.model(menuVisibility: menu)
        model.start(surface: StreamSurface())
        model.receive(fixture.update(.firstFrame))
        await clock.waitForSleeps(1)
        await clock.advance()
        await menu.waitForPendingHide()
        if state == "revealed" { menu.reveal() }
        if state == "expanded" { model.showControls() }
        let tablet = UIDevice.current.userInterfaceIdiom == .pad
        let size = tablet ? CGSize(width: 1024, height: 768) : CGSize(width: 956, height: 440)
        let name = "\(tablet ? "ipad" : "iphone")-\(dark ? "dark" : "light")-\(state)"
        try await NativeUIRenderTests().record(
            ZStack { Color.black.ignoresSafeArea(); StreamControls(model: model, close: {}) }
                .frame(width: size.width, height: size.height),
            name: name, size: size, dark: dark, textSize: .large)
        model.stop()
        await model.waitUntilStopped()
        await clock.advance()
    }

    @Test(arguments: [false, true])
    func mouseSettings(dark: Bool) async throws {
        let fixture = LauncherFixture()
        let settings = GlimmerSettings(profile: .constant(.native120), model: fixture.model())
        let host = UIHostingController(rootView: NavigationStack { settings.settingsPage(.input) })
        let tablet = UIDevice.current.userInterfaceIdiom == .pad
        let size = tablet ? CGSize(width: 768, height: 1024) : CGSize(width: 390, height: 844)
        let name = "\(tablet ? "ipad" : "iphone")-\(dark ? "dark" : "light")-mouse-settings"
        try await NativeUIRenderTests().recordController(host, name: name, size: size, dark: dark,
            portrait: true, prepare: {
                guard let scroll = Self.scrollView(in: host.view) else {
                    Issue.record("Input settings must scroll")
                    return
                }
                let bottom = max(-scroll.adjustedContentInset.top,
                                 scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
                scroll.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
            }, textSize: .large)
    }

    private static func scrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
    }

    @Test(arguments: [false, true])
    func settings(dark: Bool) async throws {
        let fixture = LauncherFixture()
        let settings = GlimmerSettings(profile: .constant(.native120), model: fixture.model())
        let tablet = UIDevice.current.userInterfaceIdiom == .pad
        let size = tablet ? CGSize(width: 768, height: 1024) : CGSize(width: 390, height: 844)
        let name = "\(tablet ? "ipad" : "iphone")-\(dark ? "dark" : "light")-settings"
        try await NativeUIRenderTests().record(NavigationStack { settings.settingsPage(.connection) },
            name: name, size: size, dark: dark, textSize: .large, portrait: true)
    }
}
