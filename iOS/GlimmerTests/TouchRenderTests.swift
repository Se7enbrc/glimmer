// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

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
                try await record(view.preferredColorScheme(.dark), name: "\(name)-\(state)",
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

    private func record(_ content: some View, name: String, size: CGSize, dark: Bool) async throws {
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
        .overlay(alignment: .top) {
            Text("ALPINE RUN").font(.caption).tracking(3).foregroundStyle(.white).padding(.top, 28)
        }
        .overlay(alignment: .bottomLeading) {
            Text("Illustrative sample frame").font(.caption2).foregroundStyle(.white.opacity(0.7)).padding(8)
        }
        .accessibilityHidden(true)
    }
}
