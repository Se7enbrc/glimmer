// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import SwiftUI
import Testing
@testable import Glimmer

@Suite(.serialized)
@MainActor
struct TouchDeviceRenderTests {
    @Test(arguments: [false, true], [false, true])
    func actualSimulatorDisplay(dark: Bool, reverse: Bool) async throws {
        let scene = try await testWindowScene()
        let window = try #require(scene.keyWindow)
        let orientation = scene.effectiveGeometry.interfaceOrientation
        try await captureDisplay(dark: dark, reverse: reverse)
        #expect(scene.keyWindow === window)
        #expect(scene.effectiveGeometry.interfaceOrientation == orientation,
                "A render fixture must restore orientation before the next case starts")
        #expect(window.rootViewController?.presentedViewController == nil)
    }

    private func captureDisplay(dark: Bool, reverse: Bool) async throws {
        let scene = try await testWindowScene()
        let connection = StreamConnection(video: ConnectionTestVideoSink()) { _, _ in }
        let capture = TouchGamepadCapture(input: connection.input)
        #expect(capture.attach())
        var presence: ((Bool) -> Void)?
        let id = UUID()
        // This touch-only fixture owns its gamepad; hardware discovery belongs to the hardware-input tests.
        let model = StreamSessionModel(launch: testLaunch(), makePlayback: { _, _, _ in
            StreamPlayback(id: id, events: AsyncStream { _ in }, start: { nil }, stop: {}, screenChanged: {},
                           focusInput: { capture.setEnabled($0) },
                           observeControllers: { presence = $0; $0(false) }, touchGamepad: capture,
                           showTouchControls: { requested in
                               if requested { capture.attach() } else { capture.detach() }
                           })
        })
        let host = StreamViewController(model: model, close: {})
        let phone = scene.traitCollection.userInterfaceIdiom != .pad
        let mask: UIInterfaceOrientationMask = phone ? (reverse ? .landscapeRight : .landscapeLeft) : .all
        let root = FixtureViewportController(content: host, size: nil, orientations: mask)
        root.overrideUserInterfaceStyle = dark ? .dark : .light
        let rendering = NativeUIRenderTests()
        defer { capture.detach() }
        let sample = UIHostingController(rootView: TouchSampleFrame().ignoresSafeArea())
        host.addChild(sample)
        host.view.insertSubview(sample.view, aboveSubview: host.surface)
        sample.didMove(toParent: host)
        sample.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sample.view.frame = host.view.bounds
        var failure: (any Error)?
        do {
            try await rendering.withRenderPresentation(root, scene: scene) { window in
                // Resizable iPad scenes keep their current window geometry.
                if phone {
                    let target: UIInterfaceOrientation = reverse ? .landscapeRight : .landscapeLeft
                    root.setNeedsUpdateOfSupportedInterfaceOrientations()
                    try await rendering.requestOrientation(scene, mask, settling: root,
                        matches: { scene.effectiveGeometry.interfaceOrientation == target })
                }
                try await rendering.waitForSceneSize(root, in: scene)
                model.receive(.init(sessionID: id, attemptID: UUID(), event: .firstFrame))
                var playingFrames: [TouchElement: CGRect]?
                for state in ["before", "after", "editor", "physical", "show-menu", "override",
                              "hide-menu", "hidden", "disconnected", "bright", "bright-active",
                              "dim", "dim-active", "mouse"] {
                    let exposure = state.hasPrefix("bright") ? 0.9 : state.hasPrefix("dim") ? -0.75 : 0
                    if exposure != 0 { model.overlayAppearance.update(luminance: exposure > 0 ? 0.85 : 0.01) }
                    sample.rootView = TouchSampleFrame(exposure: exposure)
                        .ignoresSafeArea()
                    transition(state, model: model, capture: capture, presence: presence)
                    model.editingTouchControls = state == "editor"
                    for child in host.children where child !== sample { child.view.isHidden = state == "before" }
                    if state == "mouse", let registration = capture.registration {
                        model.receive(.init(sessionID: id, attemptID: UUID(),
                                            event: .input(.mouseMode(registration, enabled: true))))
                    }
                    pressFixture(in: host, active: state.hasSuffix("active"))
                    window.layoutIfNeeded()
                    try await Task.sleep(for: .milliseconds(250))
                    if phone { #expect(window.bounds.width > window.bounds.height) }
                    if state == "physical" || state == "hidden" { verifyMouseOnly(host) }
                    if state == "after" { playingFrames = try verifyAppearance(host, dark: dark) }
                    if state == "mouse" {
                        let view = try #require(touchView(in: host.view))
                        let frames = view.controls.mapValues(\.frame)
                        #expect(playingFrames == frames)
                    }
                    let style = "\(dark ? "dark" : "light")-\(reverse ? "right" : "left")"
                    try record(window, name: "actual-\(UIDevice.current.model.lowercased())-\(style)-\(state)")
                }
            }
        } catch { failure = error }
        model.stop()
        await model.waitUntilStopped()
        await connection.stop()
        if let failure { throw failure }
    }

    @Test(arguments: [false, true])
    func touchMenuButtonReceivesItsTapAndOpensTheStreamMenu(hardwareConnected: Bool) async throws {
        let scene = try await testWindowScene()
        let connection = StreamConnection(video: ConnectionTestVideoSink()) { _, _ in }
        let capture = TouchGamepadCapture(input: connection.input)
        #expect(capture.attach())
        let id = UUID()
        let clock = WindowResizeClock()
        let visibility = StreamMenuVisibility(voiceOver: false, sleep: clock.sleep)
        let model = StreamSessionModel(launch: testLaunch(), menuVisibility: visibility, makePlayback: { _, _, _ in
            StreamPlayback(id: id, events: AsyncStream { _ in }, start: { nil }, stop: {}, screenChanged: {},
                           focusInput: { capture.setEnabled($0) },
                           observeControllers: { $0(false) }, touchGamepad: capture)
        })
        let host = StreamViewController(model: model, close: {})
        let rendering = NativeUIRenderTests()
        defer { capture.detach() }
        var failure: (any Error)?
        do {
            try await rendering.withRenderPresentation(host, scene: scene) { window in
                try await rendering.waitForOrientation(scene, portrait: false, controller: host)
                model.start(surface: host.surface)
                await model.waitUntilStartFinishes()
                model.receive(.init(sessionID: id, attemptID: UUID(), event: .firstFrame))
                #expect(host.keyboardMouseCapture == nil)
                model.hardwareConnectionChanged(hardwareConnected)
                if hardwareConnected {
                    #expect(!model.touchControlsVisible)
                    model.toggleTouchControls()
                }
                var menu: TouchMenuButton?
                for _ in 0..<100 where menu?.window == nil {
                    window.layoutIfNeeded()
                    menu = touchView(in: host.view)?.menuButton
                    try await Task.sleep(for: .milliseconds(20))
                }
                let button = try #require(menu, """
                    \(model.phase), controls: \(model.controlsVisible),
                    hardware: \(model.hardwareInputConnected), geometry: \(model.touchGeometryUsable)
                    """)
                await clock.waitForSleeps(1)
                await clock.advance()
                await visibility.waitForPendingHide()
                #expect(!visibility.visible && !visibility.hasPendingHide)
                window.layoutIfNeeded()
                #expect(button.alpha == 1 && button.isUserInteractionEnabled && !button.accessibilityElementsHidden)
                #expect(model.touchControlsVisible && !model.controlsVisible)
                // A real tap starts at the button's centre and must reach the button, not the video below it.
                let centre = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: window)
                #expect(window.hitTest(centre, with: nil) === button)
                button.sendActions(for: .primaryActionTriggered)
                #expect(model.controlsVisible && !model.inputFocused)
            }
        } catch { failure = error }
        model.stop()
        await model.waitUntilStopped()
        await connection.stop()
        if let failure { throw failure }
    }

    private func pressFixture(in host: StreamViewController, active: Bool) {
        guard let button = touchView(in: host.view)?.controls[.a] as? TouchButton,
              let action = button.accessibilityCustomActions?[active ? 0 : 1] else { return }
        _ = action.actionHandler?(action)
        #expect(button.isHighlighted == active)
    }

    private func verifyAppearance(_ host: StreamViewController, dark: Bool) throws -> [TouchElement: CGRect] {
        let view = try #require(touchView(in: host.view), """
            \(host.model.phase), controls: \(host.model.controlsVisible),
            hardware: \(host.model.hardwareInputConnected), geometry: \(host.model.touchGeometryUsable)
            """)
        #expect(view.traitCollection.userInterfaceStyle == (dark ? .dark : .light))
        let button = try #require(view.controls[.a] as? UIButton)
        var red: CGFloat = 0
        #expect(button.titleColor(for: .normal)?.getRed(&red, green: nil, blue: nil, alpha: nil) == true)
        #expect(dark ? red > 0.8 : red < 0.2)
        let colors = TouchAppearance.colors(style: dark ? .dark : .light,
                                           contrast: false, opaque: false, pressed: false)
        let label = try #require(button.subviews.compactMap { $0 as? TouchGlyphLabel }.first)
        #expect(label.colors == colors)
        return view.controls.mapValues(\.frame)
    }

    private func verifyMouseOnly(_ host: StreamViewController) {
        #expect(touchView(in: host.view) == nil)
        #expect(host.touchCapture?.primaryTap.isEnabled == true)
        #expect(host.touchCapture?.pointerPan.isEnabled == true)
    }

    private func transition(_ state: String, model: StreamSessionModel, capture: TouchGamepadCapture,
                            presence: ((Bool) -> Void)?) {
        switch state {
        case "physical":
            capture.detach()
            presence?(true)
            #expect(model.controllerConnected && !model.touchControlsVisible)
        case "show-menu", "hide-menu": model.showControls()
        case "override":
            model.toggleTouchControls()
            model.resumeInput()
            #expect(model.controllerConnected && model.touchControlsVisible)
        case "hidden":
            model.toggleTouchControls()
            model.resumeInput()
            #expect(model.controllerConnected && !model.touchControlsVisible)
        case "disconnected":
            capture.attach()
            presence?(false)
            #expect(!model.controllerConnected && model.touchControlsVisible)
        default: break
        }
    }

    private func record(_ window: UIWindow, name: String) throws {
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let data = try #require(image.pngData())
        Attachment.record(Array(data), named: "\(name).png")
    }

    private func touchView(in view: UIView) -> TouchGamepadView? {
        if let touch = view as? TouchGamepadView { return touch }
        return view.subviews.lazy.compactMap { touchView(in: $0) }.first
    }
}
