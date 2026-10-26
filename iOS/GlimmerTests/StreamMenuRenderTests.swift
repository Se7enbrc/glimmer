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
            ZStack { Color.black.ignoresSafeArea(); StreamControls(model: model, close: {}) },
            name: name, size: size, dark: dark, textSize: .large)
        model.stop()
        await model.waitUntilStopped()
        await clock.advance()
    }

    #if GLIMMER_DIAGNOSTICS
    @Test(arguments: [false, true])
    func settings(dark: Bool) async throws {
        let fixture = LauncherFixture()
        let settings = GlimmerSettings(profile: .constant(.native120), stick: .constant(.right), model: fixture.model())
        let tablet = UIDevice.current.userInterfaceIdiom == .pad
        let size = tablet ? CGSize(width: 768, height: 1024) : CGSize(width: 390, height: 844)
        let name = "\(tablet ? "ipad" : "iphone")-\(dark ? "dark" : "light")-settings"
        try await NativeUIRenderTests().record(NavigationStack { settings.settingsPage(.diagnostics) },
            name: name, size: size, dark: dark, textSize: .large, portrait: true)
    }
    #endif
}
