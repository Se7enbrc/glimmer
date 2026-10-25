// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import SwiftUI
import Testing
@testable import Glimmer

@Suite(.serialized)
@MainActor
struct TouchRenderTests {
    struct Viewport: Sendable {
        let name: String
        let size: CGSize
        var fold = false
    }
    nonisolated static let viewports: [Viewport] = [
        .init(name: "iphone-small", size: CGSize(width: 844, height: 390)),
        .init(name: "iphone-max", size: CGSize(width: 956, height: 440)),
        .init(name: "ipad-mini", size: CGSize(width: 1133, height: 744)),
        .init(name: "ipad-large", size: CGSize(width: 1376, height: 1032)),
        .init(name: "ipad-resized", size: CGSize(width: 744, height: 520)),
        .init(name: "duo-outer", size: CGSize(width: 760, height: 360)),
        .init(name: "duo-inner", size: CGSize(width: 1100, height: 820)),
        .init(name: "duo-fold", size: CGSize(width: 1100, height: 820), fold: true)
    ]

    @Test(arguments: viewports, [false, true])
    func beforeAfterAndEditor(viewport: Viewport, dark: Bool) async throws {
        for reverse in [false, true] {
            let inset: CGFloat = viewport.size.height < 500 ? 48 : 24
            let safe = CGRect(x: reverse ? 16 : inset, y: 8,
                              width: viewport.size.width - inset - 16, height: viewport.size.height - 29)
            let region = viewport.fold ? [CGRect(x: 0, y: 395, width: viewport.size.width, height: 20)] : []
            let area = TouchLayout.playableArea(safe, avoiding: region)
            let name = "\(viewport.name)-\(dark ? "dark" : "light")-\(reverse ? "right" : "left")"
            for state in ["before", "after", "editor"] {
                let view = ZStack {
                    TouchSampleFrame()
                    if state == "after" {
                        TouchPlayControls(layout: TouchLayout(), area: area, preview: true, showControls: {})
                    } else if state == "editor" {
                        TouchLayoutEditor(launch: testLaunch(), area: area, close: {})
                    }
                }
                try await record(view, name: "\(name)-\(state)",
                                 size: viewport.size, dark: dark)
            }
        }
    }

    @Test func accessibilityLabelsAndPassThroughMatchVisibleHitFrames() {
        let area = CGRect(x: 48, y: 8, width: 780, height: 353)
        let view = TouchGamepadView(frame: CGRect(x: 0, y: 0, width: 844, height: 390))
        view.configure(capture: nil, layout: TouchLayout(), area: area, preview: true)
        view.layoutIfNeeded()
        #expect(view.hitTest(CGPoint(x: 422, y: 160), with: nil) == nil)
        #expect(StreamTouchCapture.acceptsTouch(startingIn: view))
        for (element, control) in view.controls {
            #expect(control.accessibilityLabel == element.name)
            #expect(control.frame.width >= 44 && control.frame.height >= 44)
            #expect(view.hitTest(control.center, with: nil) != nil)
            #expect(!StreamTouchCapture.acceptsTouch(startingIn: control))
            for child in control.subviews { #expect(!StreamTouchCapture.acceptsTouch(startingIn: child)) }
        }
        view.mouseMode(true, leftStick: false)
        #expect(view.controls[.rightStick]?.accessibilityLabel == "Pointer")
        #expect(view.controls[.rightTrigger]?.accessibilityLabel == "Primary click")
        #expect(view.controls[.rightShoulder]?.accessibilityLabel == "Secondary click")
        view.mouseMode(false, leftStick: false)
        #expect(view.controls[.a]?.accessibilityLabel == "A")
    }

    @Test func editorAtLargestTextSize() async throws {
        let area = CGRect(x: 48, y: 8, width: 780, height: 353)
        try await record(ZStack {
            TouchSampleFrame()
            TouchLayoutEditor(launch: testLaunch(), area: area, close: {}).dynamicTypeSize(.accessibility5)
        }, name: "editor-largest-text", size: CGSize(width: 844, height: 390), dark: true)
    }

    @Test(arguments: viewports, [false, true])
    func physicalControllerOverride(viewport: Viewport, dark: Bool) async throws {
        let connection = StreamConnection(video: ConnectionTestVideoSink()) { _, _ in }
        let capture = TouchGamepadCapture(input: connection.input)
        let id = UUID()
        let model = StreamSessionModel(launch: testLaunch(), makePlayback: { _, _, _ in
            StreamPlayback(id: id, events: AsyncStream { _ in }, start: {}, stop: {}, screenChanged: {},
                           focusInput: { capture.setEnabled($0) }, observeControllers: { $0(true) },
                           touchGamepad: capture, showTouchControls: { requested in
                               if requested { capture.attach() } else { capture.detach() }
                           })
        })
        model.start(surface: StreamSurface())
        await model.waitUntilStartFinishes()
        defer { capture.detach(); model.stop() }
        model.receive(.init(sessionID: id, attemptID: UUID(), event: .firstFrame))
        for state in ["physical", "show-menu", "override", "hide-menu"] {
            if state.hasSuffix("menu") { model.showControls() }
            if state == "override" { model.toggleTouchControls(); model.resumeInput() }
            let view = ZStack {
                TouchSampleFrame()
                StreamControls(model: model, close: {})
            }
            let size = viewport.fold ? CGSize(width: viewport.size.width, height: 395) : viewport.size
            try await record(view, name: "override-\(viewport.name)-\(dark ? "dark" : "light")-\(state)",
                             size: size, dark: dark)
        }
        model.stop()
        await model.waitUntilStopped()
        await connection.stop()
    }

    @Test(arguments: viewports, [false, true])
    func appearanceOverBrightAndDarkFrames(viewport: Viewport, dark: Bool) async throws {
        let size = viewport.fold ? CGSize(width: viewport.size.width, height: 395) : viewport.size
        let area = CGRect(origin: .zero, size: size).insetBy(dx: 24, dy: 12)
        for bright in [false, true] {
            for editing in [false, true] {
                let content = ZStack {
                    TouchSampleFrame(exposure: bright ? 0.9 : -0.75)
                    if editing {
                        TouchLayoutEditor(launch: testLaunch(), area: area, close: {})
                    } else {
                        TouchPlayControls(layout: TouchLayout(), area: area, preview: true, showControls: {})
                    }
                }
                let name = "appearance-\(viewport.name)-\(dark ? "dark" : "light")"
                    + "-\(bright ? "bright" : "dim")-\(editing ? "editor" : "play")"
                try await record(content, name: name, size: size, dark: dark)
            }
        }
    }

    @Test(arguments: viewports, [false, true])
    func opacityBoundsAndEditor(viewport: Viewport, dark: Bool) async throws {
        let size = viewport.fold ? CGSize(width: viewport.size.width, height: 395) : viewport.size
        let area = CGRect(origin: .zero, size: size).insetBy(dx: 24, dy: 12)
        let launch = testLaunch()
        let store = TouchLayoutStore(defaults: .standard)
        let family = TouchLayout.family(in: area)
        let previous = store.load(pcID: launch.pcID, appID: launch.appID, family: family)
        defer { store.save(previous, pcID: launch.pcID, appID: launch.appID, family: family) }
        for opacity in [0.1, 0.2, 0.6] {
            var layout = TouchLayout()
            layout.opacity = opacity
            store.save(layout, pcID: launch.pcID, appID: launch.appID, family: family)
            for bright in [false, true] {
                for editing in [false, true] {
                    let content = ZStack {
                        TouchSampleFrame(exposure: bright ? 0.9 : -0.75)
                        if editing {
                            TouchLayoutEditor(launch: launch, area: area, close: {})
                        } else {
                            TouchPlayControls(layout: layout, area: area, preview: true, showControls: {})
                        }
                    }
                    let name = "opacity-\(viewport.name)-\(dark ? "dark" : "light")-\(Int(opacity * 100))"
                        + "-\(bright ? "bright" : "dim")-\(editing ? "editor" : "play")"
                    try await record(content, name: name, size: size, dark: dark,
                                     opacity: editing ? opacity : nil)
                }
            }
        }
    }

    @Test func nativeOpacitySliderPreviewsBothEndpointsWithoutSaving() async throws {
        let launch = testLaunch()
        let store = TouchLayoutStore(defaults: .standard)
        let saved = store.load(pcID: launch.pcID, appID: launch.appID, family: .compact)
        store.save(TouchLayout(), pcID: launch.pcID, appID: launch.appID, family: .compact)
        defer { store.save(saved, pcID: launch.pcID, appID: launch.appID, family: .compact) }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let size = CGSize(width: 844, height: 390)
        let area = CGRect(origin: .zero, size: size).insetBy(dx: 24, dy: 12)
        let host = UIHostingController(rootView: TouchLayoutEditor(launch: launch, area: area, close: {})
            .frame(width: size.width, height: size.height))
        window.rootViewController = TouchViewportController(content: host, size: size)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        host.view.layoutIfNeeded()
        _ = try await waitForOpacity(0.2, in: host.view)
        let slider = try #require(descendants(host.view).compactMap { $0 as? UISlider }.last)
        for (nativeValue, opacity) in [(slider.maximumValue, 0.6), (slider.minimumValue, 0.1)] {
            slider.value = nativeValue
            slider.sendActions(for: .valueChanged)
            _ = try await waitForOpacity(opacity, in: host.view)
            #expect(store.load(pcID: launch.pcID, appID: launch.appID, family: .compact).opacity == 0.2)
        }
    }

    private func waitForOpacity(_ opacity: Double, in view: UIView) async throws -> TouchGamepadView {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if let preview = descendants(view).compactMap({ $0 as? TouchGamepadView }).first,
               preview.opacity == opacity { return preview }
            try await Task.sleep(for: .milliseconds(20))
        }
        let preview = try #require(descendants(view).compactMap { $0 as? TouchGamepadView }.first)
        try #require(preview.opacity == opacity)
        return preview
    }

    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    private func record(_ content: some View, name: String, size: CGSize, dark: Bool,
                        opacity: Double? = nil) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: content.frame(width: size.width, height: size.height)
            .environment(\.colorScheme, dark ? .dark : .light).ignoresSafeArea())
        host.overrideUserInterfaceStyle = dark ? .dark : .light
        window.rootViewController = TouchViewportController(content: host, size: size)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        host.view.frame = CGRect(origin: .zero, size: size)
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        if let opacity {
            let views = descendants(host.view)
            let preview = try #require(views.compactMap { $0 as? TouchGamepadView }.first)
            let slider = try #require(views.compactMap { $0 as? UISlider }.last)
            #expect(preview.opacity == opacity)
            #expect(abs(Double(slider.value) - (opacity - 0.1) / 0.5) < 0.00001)
        }
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { _ in host.view.drawHierarchy(in: CGRect(origin: .zero, size: size),
                                                                 afterScreenUpdates: true) }
        let data = try #require(image.pngData())
        Attachment.record(Array(data), named: "\(name).png")
    }
}

@MainActor
private final class TouchViewportController: UIViewController {
    let content: UIViewController
    let size: CGSize

    init(content: UIViewController, size: CGSize) {
        self.content = content
        self.size = size
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(content)
        view.addSubview(content.view)
        content.didMove(toParent: self)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        content.view.frame = CGRect(origin: .zero, size: size)
    }
}

struct TouchSampleFrame: View {
    var exposure: Double = 0

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
                Gradient(colors: [Color(red: 0.26, green: 0.43, blue: 0.53),
                                  Color(red: 0.76, green: 0.80, blue: 0.72)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            for (index, heights) in [[0.55, 0.17, 0.43, 0.23, 0.47, 0.14, 0.43],
                                     [0.65, 0.43, 0.61, 0.46, 0.62, 0.34, 0.55]].enumerated() {
                var ridge = Path()
                ridge.move(to: CGPoint(x: 0, y: size.height))
                for (offset, height) in heights.enumerated() {
                    ridge.addLine(to: CGPoint(x: CGFloat(offset) / 6 * size.width, y: height * size.height))
                }
                ridge.addLine(to: CGPoint(x: size.width, y: size.height))
                ridge.closeSubpath()
                context.fill(ridge, with: .color(index == 0
                    ? Color(red: 0.36, green: 0.49, blue: 0.48) : Color(red: 0.16, green: 0.32, blue: 0.30)))
            }
        }
        .overlay(exposure > 0 ? Color.white.opacity(exposure) : Color.black.opacity(-exposure))
        .overlay(alignment: .top) {
            Text("ALPINE RUN").font(.caption).tracking(3)
                .foregroundStyle(exposure > 0 ? .black : .white).padding(.top, 28)
        }
        .overlay(alignment: .bottomLeading) {
            Text("Illustrative sample frame").font(.caption2)
                .foregroundStyle((exposure > 0 ? Color.black : .white).opacity(0.7)).padding(8)
        }
        .accessibilityHidden(true)
    }
}
