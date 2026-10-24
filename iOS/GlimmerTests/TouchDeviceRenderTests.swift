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
        let model = StreamSessionModel(launch: testLaunch(), makePlayback: { _, _, _ in
            StreamPlayback(id: id, events: AsyncStream { _ in }, start: {}, stop: {}, screenChanged: {},
                           input: connection.input, focusInput: { capture.setEnabled($0) },
                           observeControllers: { presence = $0; $0(false) }, touchGamepad: capture,
                           showTouchControls: { requested in
                               if requested { capture.attach() } else { capture.detach() }
                           })
        })
        let window = UIWindow(windowScene: scene)
        let host = StreamViewController(model: model, close: {})
        host.overrideUserInterfaceStyle = dark ? .dark : .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { capture.detach(); model.stop(); window.isHidden = true; previous?.makeKeyAndVisible() }
        let sample = UIHostingController(rootView: TouchSampleFrame().ignoresSafeArea())
        host.addChild(sample)
        host.view.insertSubview(sample.view, aboveSubview: host.surface)
        sample.didMove(toParent: host)
        sample.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sample.view.frame = host.view.bounds
        try await Task.sleep(for: .milliseconds(300))
        host.setNeedsUpdateOfSupportedInterfaceOrientations()
        let target: UIInterfaceOrientation = reverse ? .landscapeRight : .landscapeLeft
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: reverse ? .landscapeRight : .landscapeLeft)) { error in
            Attachment.record(Array(error.localizedDescription.utf8), named: "rotation-error.txt")
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while scene.effectiveGeometry.interfaceOrientation != target, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(scene.effectiveGeometry.interfaceOrientation == target)
        model.receive(.init(sessionID: id, attemptID: UUID(), event: .firstFrame))
        var playingFrames: [TouchElement: CGRect]?
        for state in ["before", "after", "editor", "physical", "show-menu", "override",
                      "hide-menu", "hidden", "disconnected", "mouse"] {
            transition(state, model: model, capture: capture, presence: presence)
            model.editingTouchControls = state == "editor"
            for child in host.children where child !== sample { child.view.isHidden = state == "before" }
            if state == "mouse", let registration = capture.registration {
                model.receive(.init(sessionID: id, attemptID: UUID(),
                                    event: .input(.mouseMode(registration, enabled: true))))
            }
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(250))
            #expect(window.bounds.width > window.bounds.height)
            if state == "physical" || state == "hidden" { verifyMouseOnly(host) }
            if state == "after" { playingFrames = touchView(in: host.view)?.controls.mapValues(\.frame) }
            if state == "mouse" {
                let frames = try #require(touchView(in: host.view)?.controls.mapValues(\.frame))
                #expect(playingFrames == frames)
            }
            let style = "\(dark ? "dark" : "light")-\(reverse ? "right" : "left")"
            try record(window, name: "actual-\(UIDevice.current.model.lowercased())-\(style)-\(state)")
        }
        model.stop()
        await model.waitUntilStopped()
        await connection.stop()
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
