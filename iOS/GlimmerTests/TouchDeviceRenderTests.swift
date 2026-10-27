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
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
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
        let window = UIWindow(windowScene: scene)
        let host = StreamViewController(model: model, close: {})
        host.overrideUserInterfaceStyle = dark ? .dark : .light
        let orientation = TouchOrientationController()
        let phone = scene.traitCollection.userInterfaceIdiom != .pad
        orientation.mask = phone ? (reverse ? .landscapeRight : .landscapeLeft) : .all
        orientation.addChild(host)
        orientation.view.addSubview(host.view)
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.view.frame = orientation.view.bounds
        host.didMove(toParent: orientation)
        window.rootViewController = orientation
        window.makeKeyAndVisible()
        defer { capture.detach(); model.stop(); window.isHidden = true; previous?.makeKeyAndVisible() }
        let sample = UIHostingController(rootView: TouchSampleFrame().ignoresSafeArea())
        host.addChild(sample)
        host.view.insertSubview(sample.view, aboveSubview: host.surface)
        sample.didMove(toParent: host)
        sample.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sample.view.frame = host.view.bounds
        // Resizable iPad scenes keep their current window geometry.
        let target: UIInterfaceOrientation? = phone ? (reverse ? .landscapeRight : .landscapeLeft) : nil
        try await orientation.settle(in: scene, target: target)
        if let target { try #require(scene.effectiveGeometry.interfaceOrientation == target) }
        model.receive(.init(sessionID: id, attemptID: UUID(), event: .firstFrame))
        var playingFrames: [TouchElement: CGRect]?
        for state in ["before", "after", "editor", "physical", "show-menu", "override",
                      "hide-menu", "hidden", "disconnected", "bright", "bright-active", "dim", "dim-active", "mouse"] {
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
        model.stop()
        await model.waitUntilStopped()
        await connection.stop()
    }

    @Test(arguments: [false, true])
    func touchMenuButtonReceivesItsTapAndOpensTheStreamMenu(hardwareConnected: Bool) async throws {
        let scene = try await testWindowScene()
        let previous = scene.keyWindow
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
        let window = UIWindow(windowScene: scene)
        let host = StreamViewController(model: model, close: {})
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { capture.detach(); model.stop(); window.isHidden = true; previous?.makeKeyAndVisible() }
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
        model.stop()
        await model.waitUntilStopped()
        await connection.stop()
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

@MainActor
private final class TouchOrientationController: UIViewController {
    var mask: UIInterfaceOrientationMask = .all
    private let updates = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private var appeared = false
    private var transitioning = false
    private var geometryError: (any Error)?

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { mask }
    override var childForStatusBarHidden: UIViewController? { children.first }
    override var childForHomeIndicatorAutoHidden: UIViewController? { children.first }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        appeared = true
        updates.continuation.yield(())
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updates.continuation.yield(())
    }

    override func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        transitioning = true
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            guard let self else { return }
            transitioning = false
            updates.continuation.yield(())
        }
    }

    func settle(in scene: UIWindowScene, target: UIInterfaceOrientation?) async throws {
        // Room for up to four rotation attempts; each normally settles well under a second.
        let deadline = Timer(timeInterval: 15, repeats: false) { [updates] _ in
            updates.continuation.finish()
        }
        RunLoop.main.add(deadline, forMode: .common)
        defer { deadline.invalidate() }
        var iterator = updates.stream.makeAsyncIterator()
        while !appeared || transitioning {
            try #require(await iterator.next() != nil, "UIKit did not settle the scene in time")
        }
        guard let target else { return }
        setNeedsUpdateOfSupportedInterfaceOrientations()
        // The simulator refuses rotations while another transition settles; ask again as a real app would.
        for attempt in 1...4 {
            geometryError = nil
            while transitioning {
                try #require(await iterator.next() != nil, "UIKit did not settle the scene in time")
            }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { @Sendable [weak self] error in
                Task { @MainActor in
                    self?.geometryError = error
                    self?.updates.continuation.yield(())
                }
            }
            while geometryError == nil, transitioning || scene.effectiveGeometry.interfaceOrientation != target {
                try #require(await iterator.next() != nil, "UIKit did not settle the scene in time")
            }
            if geometryError == nil || attempt == 4 { break }
        }
        try Task.checkCancellation()
        if let geometryError { throw geometryError }
    }
}
