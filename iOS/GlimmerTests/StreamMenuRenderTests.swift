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
