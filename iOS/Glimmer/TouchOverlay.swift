// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import SwiftUI

struct TouchOverlay: View {
    let model: StreamSessionModel
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    var body: some View {
        GeometryReader { geometry in
            let area = Self.area(geometry)
            // Zero-sized: accessibility hit tests land even on a hidden full-size view, covering the stream menu.
            Color.clear.frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
                .onChange(of: area, initial: true) { _, area in
                    guard geometry.size.width > 0, geometry.size.height > 0 else { return }
                    model.touchGeometryChanged(usable: !TouchLayout().frames(in: area).isEmpty)
                }
            if model.editingTouchControls {
                TouchLayoutEditor(launch: model.launch, area: area) { model.editingTouchControls = false }
            } else if model.touchControlsVisible {
                let layout = TouchLayoutStore(defaults: PersistentStorage.defaults).load(
                    pcID: model.launch.pcID, appID: model.launch.appID, family: TouchLayout.family(in: area))
                TouchPlayControls(capture: model.touchGamepad, layout: layout, area: area,
                                  mouseMode: model.touchMouseActive,
                                  menuVisible: model.menuVisibility.visible,
                                  showControls: model.showControls)
            } else if model.inputFocused {
                let layout = TouchLayoutStore(defaults: PersistentStorage.defaults).load(
                    pcID: model.launch.pcID, appID: model.launch.appID, family: TouchLayout.family(in: area))
                TouchControlsButton(area: area, opacity: layout.opacity, visible: model.menuVisibility.visible,
                                    showControls: model.showControls)
            }
        }
        .onChange(of: voiceOver, initial: true) { _, enabled in model.menuVisibility.voiceOverChanged(enabled) }
    }

    static func area(_ geometry: GeometryProxy) -> CGRect {
        // The hosting view proposes safe content bounds; subtracting its insets again doubles the notch gap.
        let safe = CGRect(origin: .zero, size: geometry.size)
        var regions: [CGRect] = []
        #if compiler(>=6.4)
        if #available(iOS 27.1, *) {
            regions = (geometry.reservedRegions(kind: .division)
                + geometry.reservedRegions(kind: .occlusion)).filter(\.isActive).map(\.frame)
        }
        #endif
        return TouchLayout.playableArea(safe, avoiding: regions)
    }
}

struct TouchPlayControls: View {
    var capture: TouchGamepadCapture?
    let layout: TouchLayout
    let area: CGRect
    var mouseMode = false
    var menuVisible = true
    var preview = false
    let showControls: () -> Void

    var body: some View {
        ZStack {
            TouchGamepadRepresentation(capture: capture, layout: layout, area: area,
                                       mouseMode: mouseMode,
                                       menuVisible: menuVisible, preview: preview,
                                       showControls: showControls)
            if TouchLayout().frames(in: area).isEmpty {
                Text("Make this window larger to use touch controls.")
                    .font(.callout).padding().background(.regularMaterial, in: .capsule)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct TouchControlsButton: View {
    let area: CGRect
    var opacity = TouchLayout.defaultOpacity
    let visible: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let showControls: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let frame = TouchLayout.menuFrame(in: area)
            Button("Show controls", systemImage: "ellipsis", action: showControls)
                .labelStyle(.iconOnly).buttonStyle(TouchMenuStyle(opacity: opacity))
                .opacity(visible ? 1 : 0).allowsHitTesting(visible).accessibilityHidden(!visible)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: visible)
                .position(x: min(frame.midX, geometry.size.width - 22),
                          y: min(frame.midY, geometry.size.height - 22))
        }
    }
}

private struct TouchMenuStyle: ButtonStyle {
    let opacity: Double
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func makeBody(configuration: Configuration) -> some View {
        let colors = TouchAppearance.colors(style: colorScheme == .dark ? .dark : .light,
                                           contrast: contrast == .increased, opaque: reduceTransparency,
                                           pressed: configuration.isPressed, opacity: opacity)
        configuration.label.labelStyle(TouchMenuLabelStyle(colors: colors))
            .frame(width: 44, height: 44).contentShape(.rect)
            .background(Color(uiColor: colors.fill), in: .circle)
            .overlay { Circle().stroke(Color(uiColor: colors.border), lineWidth: contrast == .increased ? 2 : 0.75) }
    }
}

private struct TouchMenuLabelStyle: LabelStyle {
    let colors: TouchAppearance.Colors

    func makeBody(configuration: Configuration) -> some View {
        Label { configuration.title } icon: {
            if let image = TouchAppearance.symbol("ellipsis", colors: colors) {
                Image(uiImage: image)
            }
        }.labelStyle(.iconOnly)
    }
}

struct TouchGamepadRepresentation: UIViewRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var capture: TouchGamepadCapture?
    let layout: TouchLayout
    let area: CGRect
    var mouseMode = false
    var menuVisible = true
    var preview = false

    var showControls: () -> Void = {}

    func makeUIView(context: Context) -> TouchGamepadView { TouchGamepadView() }

    func updateUIView(_ view: TouchGamepadView, context: Context) {
        view.menuButton.showControls = showControls
        view.configure(capture: capture, layout: layout, area: area, preview: preview)
        view.mouseMode(mouseMode, bindings: ControllerLayoutsModel.shared.mouse)
        view.setMenuVisible(menuVisible, animated: !reduceMotion)
    }
}
