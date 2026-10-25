// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GameController
import GlimmerEngine
import Synchronization
import Testing
import UIKit
@testable import Glimmer

@MainActor
struct TouchGamepadTests {
    @Test(arguments: [UIUserInterfaceStyle.light, .dark])
    func restingControlsRevealTheGameAndOnlyActiveControlsGainContrast(style: UIUserInterfaceStyle) {
        let rest = TouchAppearance.colors(style: style, contrast: false, opaque: false, pressed: false)
        let active = TouchAppearance.colors(style: style, contrast: false, opaque: false, pressed: true)
        #expect(rest.fill.cgColor.alpha <= 0.25)
        #expect(rest.border.cgColor.alpha <= 0.25)
        #expect(rest.glyph.cgColor.alpha <= 0.8)
        #expect(active.fill.cgColor.alpha > rest.fill.cgColor.alpha && active.fill.cgColor.alpha < 0.5)
        #expect(active.glyph.cgColor.alpha > rest.glyph.cgColor.alpha)
    }

    @Test(arguments: [UIUserInterfaceStyle.light, .dark], [0.1, 0.2, 0.6])
    func opacityRetainsFindabilityAndHeldBoost(style: UIUserInterfaceStyle, opacity: Double) {
        let rest = TouchAppearance.colors(style: style, contrast: false, opaque: false,
                                         pressed: false, opacity: opacity)
        let held = TouchAppearance.colors(style: style, contrast: false, opaque: false,
                                         pressed: true, opacity: opacity)
        #expect(rest.fill.cgColor.alpha >= 0.09 && rest.fill.cgColor.alpha < 0.7)
        #expect(rest.glyph.cgColor.alpha >= 0.65 - 0.00001 && rest.edge.cgColor.alpha >= 0.78)
        #expect(held.fill.cgColor.alpha > rest.fill.cgColor.alpha)
        #expect(held.glyph.cgColor.alpha >= rest.glyph.cgColor.alpha)
        #expect(held.border.cgColor.alpha > rest.border.cgColor.alpha)
        let opaque = TouchAppearance.colors(style: style, contrast: false, opaque: true,
                                           pressed: false, opacity: opacity)
        #expect(opaque.fill.cgColor.alpha == 1)
    }

    @Test func lightButtonsUseLightSurfacesAndDarkTitles() throws {
        let button = TouchButton(.a)
        button.overrideUserInterfaceStyle = .light
        button.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        button.layoutIfNeeded()
        let fill = try #require(button.backgroundColor)
        let title = try #require(button.titleColor(for: .normal))
        var red: CGFloat = 0
        #expect(fill.getRed(&red, green: nil, blue: nil, alpha: nil))
        #expect(red > 0.8)
        #expect(title.getRed(&red, green: nil, blue: nil, alpha: nil))
        #expect(red < 0.2)
    }

    @Test(arguments: [UIUserInterfaceStyle.light, .dark], [0.1, 0.2, 0.6])
    func glyphEdgesStayLegibleAcrossVideoLuminance(style: UIUserInterfaceStyle, opacity: Double) throws {
        for pressed in [false, true] {
            for (contrast, opaque) in [(false, false), (true, false), (false, true), (true, true)] {
                let colors = TouchAppearance.colors(style: style, contrast: contrast, opaque: opaque,
                                                   pressed: pressed, opacity: opacity)
                for level in stride(from: 0.0, through: 1.0, by: 0.05) {
                    let surface = try composite(colors.fill, over: SIMD3<Double>(repeating: level))
                    let thumb = try composite(colors.thumb, over: surface)
                    for base in [surface, thumb] {
                        let glyph = luminance(try composite(colors.glyph, over: base))
                        let edge = luminance(try composite(colors.edge, over: base))
                        #expect((max(glyph, edge) + 0.05) / (min(glyph, edge) + 0.05) >= 4.5)
                    }
                }
            }
        }
    }

    @Test(arguments: [UIUserInterfaceStyle.light, .dark])
    func accessibilityCanStrengthenTheTranslucentPalette(style: UIUserInterfaceStyle) {
        let rest = TouchAppearance.colors(style: style, contrast: false, opaque: false, pressed: false)
        let contrast = TouchAppearance.colors(style: style, contrast: true, opaque: false, pressed: false)
        let opaque = TouchAppearance.colors(style: style, contrast: false, opaque: true, pressed: false)
        #expect(contrast.glyph.cgColor.alpha == 1 && contrast.edge.cgColor.alpha == 1)
        #expect(contrast.fill.cgColor.alpha > rest.fill.cgColor.alpha)
        #expect(opaque.fill.cgColor.alpha == 1)
    }

    @Test(arguments: [UIUserInterfaceStyle.light, .dark])
    func nativeTitlesHaveAnEdgeAndSymbolsReuseTheirRaster(style: UIUserInterfaceStyle) throws {
        let colors = TouchAppearance.colors(style: style, contrast: false, opaque: false, pressed: false)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = style
        let owner = UIViewController()
        window.rootViewController = owner
        let button = TouchButton(.a)
        owner.view.addSubview(button)
        window.isHidden = false
        defer { window.isHidden = true }
        button.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        button.layoutIfNeeded()
        #expect(button.traitCollection.userInterfaceStyle == style)
        let label = try #require(button.subviews.compactMap { $0 as? TouchGlyphLabel }.first)
        #expect(label.colors == colors && label.text == "A")
        #expect(button.titleLabel?.bounds.isEmpty == true && button.accessibilityLabel == TouchElement.a.name)
        let text = try #require(TouchAppearance.text("A", font: label.font, colors: colors))
        #expect(text === TouchAppearance.text("A", font: label.font, colors: colors))
        for name in ["ellipsis", "plus", "line.3.horizontal", "rectangle.on.rectangle"] {
            let first = try #require(TouchAppearance.symbol(name, colors: colors))
            #expect(first.renderingMode == .alwaysOriginal)
            #expect(first === TouchAppearance.symbol(name, colors: colors))
            let opaque = TouchAppearance.colors(style: style, contrast: false, opaque: true, pressed: false)
            #expect(first === TouchAppearance.symbol(name, colors: opaque))
        }
        #expect(button.layer.shadowOpacity == 0)
    }

    @Test func appearanceChangesPreserveHeldInputAndHitFrames() async throws {
        let connection = StreamConnection(video: ConnectionTestVideoSink()) { _, _ in }
        var submissions = 0
        let capture = TouchGamepadCapture(calls: .init(register: connection.input.registerController,
            unregister: connection.input.unregisterController, submit: { _, _, _ in submissions += 1 }))
        #expect(capture.attach())
        capture.setEnabled(true)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .light
        let owner = UIViewController()
        window.rootViewController = owner
        let view = TouchGamepadView(frame: CGRect(x: 0, y: 0, width: 844, height: 390))
        owner.view.addSubview(view)
        window.isHidden = false
        defer { window.isHidden = true }
        view.configure(capture: capture, layout: TouchLayout(), area: view.bounds.insetBy(dx: 24, dy: 12))
        view.layoutIfNeeded()
        let button = try #require(view.controls[.a] as? TouchButton)
        let hold = try #require(button.accessibilityCustomActions?.first)
        #expect(hold.actionHandler?(hold) == true)
        let frames = view.controls.mapValues(\.frame)
        let sent = submissions
        window.overrideUserInterfaceStyle = .dark
        window.layoutIfNeeded()
        #expect(view.controls.mapValues(\.frame) == frames)
        #expect(submissions == sent && capture.enabled && button.isHighlighted)
        let heldColors = TouchAppearance.colors(style: .dark, contrast: false, opaque: false, pressed: true)
        #expect(button.backgroundColor == heldColors.fill)
        let label = try #require(button.subviews.compactMap { $0 as? TouchGlyphLabel }.first)
        #expect(label.colors == heldColors)
        window.overrideUserInterfaceStyle = .light
        window.layoutIfNeeded()
        #expect(view.controls.mapValues(\.frame) == frames && submissions == sent)
        var red: CGFloat = 0
        #expect(button.titleColor(for: .normal)?.getRed(&red, green: nil, blue: nil, alpha: nil) == true)
        #expect(red < 0.2)
        capture.detach()
        await connection.stop()
    }

    @Test(arguments: [UIUserInterfaceStyle.light, .dark])
    func opacityChangesEveryControlWithoutChangingInputOrGeometry(style: UIUserInterfaceStyle) async throws {
        let connection = StreamConnection(video: ConnectionTestVideoSink()) { _, _ in }
        var submissions = 0
        let capture = TouchGamepadCapture(calls: .init(register: connection.input.registerController,
            unregister: connection.input.unregisterController, submit: { _, _, _ in submissions += 1 }))
        #expect(capture.attach())
        capture.setEnabled(true)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = style
        let owner = UIViewController()
        window.rootViewController = owner
        let view = TouchGamepadView(frame: CGRect(x: 0, y: 0, width: 844, height: 390))
        owner.view.addSubview(view)
        window.isHidden = false
        defer { window.isHidden = true }
        let area = view.bounds.insetBy(dx: 24, dy: 12)
        var layout = TouchLayout()
        view.configure(capture: capture, layout: layout, area: area)
        view.layoutIfNeeded()
        let frames = view.controls.mapValues(\.frame)
        let button = try #require(view.controls[.a] as? TouchButton)
        let hold = try #require(button.accessibilityCustomActions?.first)
        #expect(hold.actionHandler?(hold) == true)
        let sent = submissions
        for opacity in [0.1, 0.2, 0.6, 0.2] {
            layout.opacity = opacity
            view.configure(capture: capture, layout: layout, area: area)
            #expect(view.opacity == opacity)
            #expect(view.controls.mapValues(\.frame) == frames && submissions == sent)
            #expect(button.isHighlighted && capture.enabled)
            let menuColors = TouchAppearance.colors(style: style, contrast: false, opaque: false,
                                                    pressed: false, opacity: opacity)
            #expect(view.menuButton.backgroundColor == menuColors.fill)
            #expect(view.menuButton.image(for: .normal) === TouchAppearance.symbol("ellipsis", colors: menuColors))
            #expect(view.menuButton.frame == TouchLayout.menuFrame(in: area))
            #expect(view.menuButton.layer.animationKeys()?.isEmpty != false)
            for (element, control) in view.controls {
                let colors = TouchAppearance.colors(style: style, contrast: false, opaque: false,
                                                   pressed: element == .a, opacity: opacity)
                if element == .dpad {
                    let cross = try #require(control.layer.sublayers?.compactMap { $0 as? CAShapeLayer }.first)
                    #expect(cross.fillColor == colors.fill.cgColor && cross.strokeColor == colors.border.cgColor)
                } else { #expect(control.backgroundColor == colors.fill) }
                #expect(control.tintColor == colors.glyph && control.alpha == 1)
                for label in control.subviews.compactMap({ $0 as? TouchGlyphLabel }) {
                    #expect(label.colors == colors)
                }
                #expect(control.layer.animationKeys()?.isEmpty != false)
            }
        }
        capture.detach()
        await connection.stop()
    }

    @Test func overlayMenuUsesNativeActivationAndExcludesTouchMouse() {
        let view = TouchGamepadView(frame: CGRect(x: 0, y: 0, width: 956, height: 440))
        let area = view.bounds.insetBy(dx: 24, dy: 12)
        var shown = 0
        view.menuButton.showControls = { shown += 1 }
        view.configure(capture: nil, layout: TouchLayout(), area: area, preview: true)
        view.layoutIfNeeded()
        #expect(view.hitTest(view.menuButton.center, with: nil) === view.menuButton)
        #expect(!StreamTouchCapture.acceptsTouch(startingIn: view.menuButton))
        #expect(view.menuButton.accessibilityLabel == "Show controls")
        view.menuButton.sendActions(for: .primaryActionTriggered)
        #expect(shown == 1)
    }

    private func composite(_ color: UIColor, over background: SIMD3<Double>) throws -> SIMD3<Double> {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        try #require(color.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        return SIMD3(Double(red), Double(green), Double(blue)) * Double(alpha) + background * (1 - Double(alpha))
    }

    private func luminance(_ color: SIMD3<Double>) -> Double {
        let channels = [color.x, color.y, color.z].map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
    }

    @Test func nativeActivationAndAccessibilityReleaseTheirContacts() async throws {
        let connection = StreamConnection(video: ConnectionTestVideoSink()) { _, _ in }
        var samples: [ControllerInputSample] = []
        let capture = TouchGamepadCapture(calls: .init(register: connection.input.registerController,
            unregister: connection.input.unregisterController, submit: { _, sample, _ in samples.append(sample) }))
        #expect(capture.attach())
        capture.setEnabled(true)
        samples.removeAll()
        let button = TouchButton(.a)
        button.inputTracking.capture = capture
        button.sendActions(for: .primaryActionTriggered)
        #expect(samples.map(\.buttons) == [.a, []])
        samples.removeAll()
        #expect(button.accessibilityActivate())
        #expect(samples.map(\.buttons) == [.a, []])
        let trigger = TouchTrigger(.leftTrigger)
        trigger.inputTracking.capture = capture
        #expect(trigger.accessibilityActivate())
        #expect(samples.last?.leftTrigger == 1)
        trigger.accessibilityDecrement()
        #expect(samples.last?.leftTrigger == 0.9)
        trigger.accessibilityElementDidLoseFocus()
        #expect(samples.last?.leftTrigger == 0)
        let axis = TouchAxisControl(.leftStick)
        axis.inputTracking.capture = capture
        axis.accessibilityIncrement()
        #expect(samples.last?.leftStickY == 1)
        axis.accessibilityElementDidLoseFocus()
        #expect(samples.last?.leftStickY == 0)
        capture.detach()
        await connection.stop()
    }

    @Test func simultaneousOwnersReleaseIndependentlyAndRejectOldContacts() throws {
        var state = TouchGamepadState()
        let stickValue = state.begin(.leftStick)
        let stick = try #require(stickValue)
        let buttonValue = state.begin(.a)
        let button = try #require(buttonValue)
        let duplicateOwner = state.begin(.a) == nil
        #expect(duplicateOwner)
        let stickChanged = state.update(stick, value: CGPoint(x: 0.5, y: -0.25))
        #expect(stickChanged)
        let buttonPressed = state.update(button, value: CGPoint(x: 1, y: 0))
        #expect(buttonPressed)
        #expect(state.sample.buttons == .a && state.sample.leftStickX == 0.5)
        let heldUnchanged = !state.update(button, value: CGPoint(x: 1, y: 0))
        #expect(heldUnchanged)
        let buttonReleased = state.end(button)
        #expect(buttonReleased)
        #expect(state.sample.buttons.isEmpty && state.sample.leftStickX == 0.5)
        state.reset()
        let replacementValue = state.begin(.a)
        let replacement = try #require(replacementValue)
        let staleUpdateRejected = !state.update(button, value: CGPoint(x: 1, y: 0))
        #expect(staleUpdateRejected)
        let replacementPressed = state.update(replacement, value: CGPoint(x: 1, y: 0))
        #expect(replacementPressed)
        let staleEndRejected = !state.end(button)
        #expect(staleEndRejected)
        #expect(state.sample.buttons == .a)
    }

    @Test func fixedStickDeadZoneAndClampDoNotDependOnPixels() {
        for side in [96.0, 112.0, 144.0] {
            let size = CGSize(width: side, height: side)
            #expect(TouchGamepadState.stick(location: CGPoint(x: side * 0.51, y: side / 2), size: size) == .zero)
            let value = TouchGamepadState.stick(location: CGPoint(x: side * 3, y: -side * 2), size: size)
            #expect(abs(hypot(value.x, value.y) - 1) < 0.00001)
            #expect(value.x > 0 && value.y > 0)
        }
    }

    @Test func dpadSlidesAndTriggerClamps() throws {
        var state = TouchGamepadState()
        let dpadValue = state.begin(.dpad)
        let dpad = try #require(dpadValue)
        let triggerValue = state.begin(.leftTrigger)
        let trigger = try #require(triggerValue)
        let diagonalChanged = state.update(dpad, value: CGPoint(x: -1, y: 1))
        #expect(diagonalChanged)
        #expect(state.sample.buttons == [.dpadLeft, .dpadUp])
        let directionChanged = state.update(dpad, value: CGPoint(x: 1, y: 0))
        #expect(directionChanged)
        #expect(state.sample.buttons == .dpadRight)
        let fullTriggerChanged = state.update(trigger, value: CGPoint(x: 2, y: 0))
        #expect(fullTriggerChanged)
        #expect(state.sample.leftTrigger == 1)
        let releasedTriggerChanged = state.update(trigger, value: CGPoint(x: -1, y: 0))
        #expect(releasedTriggerChanged)
        #expect(state.sample.leftTrigger == 0)
    }

    @Test func adapterPreservesTimestampsAndProducesNoHeldRepeats() async throws {
        let connection = StreamConnection(video: ConnectionTestVideoSink()) { _, _ in }
        var events: [(ControllerInputSample, TimeInterval)] = []
        let capture = TouchGamepadCapture(calls: .init(register: connection.input.registerController,
            unregister: connection.input.unregisterController,
            submit: { _, sample, time in events.append((sample, time)) }))
        #expect(capture.attach())
        capture.setEnabled(true)
        events.removeAll()
        let contact = try #require(capture.begin(.a))
        capture.update(contact, value: CGPoint(x: 1, y: 0), at: 12.5)
        for _ in 0..<1000 { capture.update(contact, value: CGPoint(x: 1, y: 0), at: 12.6) }
        capture.end(contact, at: 12.75)
        #expect(events.map(\.1) == [12.5, 12.75])
        #expect(events.map { $0.0.buttons } == [.a, []])
        capture.setEnabled(false)
        capture.setEnabled(true)
        let count = events.count
        capture.update(contact, value: CGPoint(x: 1, y: 0), at: 13)
        #expect(events.count == count)
        capture.detach()
        await connection.stop()
    }

    @Test func physicalAdmissionRetiresTouchBeforeReusingSlotAndFailureRestoresFallback() async throws {
        let connection = StreamConnection(video: ConnectionTestVideoSink()) { _, _ in }
        let touch = TouchGamepadCapture(input: connection.input)
        #expect(touch.attach())
        let original = try #require(touch.registration)
        touch.setEnabled(true)
        let controller = GCController.withExtendedGamepad()
        var permit = false
        var physicalSlot: UInt8?
        let physical = IOSControllerCapture(calls: .init(register: { descriptor in
            #expect(touch.registration == nil)
            guard permit else { return nil }
            let result = connection.input.registerController(descriptor)
            physicalSlot = result?.slot
            return result
        }, unregister: connection.input.unregisterController, submit: { _, _, _ in }, focus: { _ in }),
            center: NotificationCenter(), readControllers: { [controller] })
        physical.beforeAttach = { touch.detach() }
        physical.refreshed = { connected in if !connected { touch.attach(); touch.setEnabled(true) } }
        physical.start()
        #expect(touch.enabled && touch.registration != nil)
        permit = true
        physical.refresh()
        #expect(touch.registration == nil && !touch.enabled)
        #expect(physicalSlot == original.slot)
        physical.stop()
        await connection.stop()
    }
}
