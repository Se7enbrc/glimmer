// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import SwiftUI

struct TouchOverlay: View {
    let model: StreamSessionModel

    var body: some View {
        GeometryReader { geometry in
            let area = Self.area(geometry)
            if model.editingTouchControls {
                TouchLayoutEditor(launch: model.launch, area: area) { model.editingTouchControls = false }
            } else if model.touchControlsVisible {
                let layout = TouchLayoutStore(defaults: .standard).load(
                    pcID: model.launch.pcID, appID: model.launch.appID, family: TouchLayout.family(in: area))
                TouchPlayControls(capture: model.touchGamepad, layout: layout, area: area,
                                  mouseMode: model.touchMouseActive,
                                  leftStick: model.launch.mouseStick == .left, showControls: model.showControls)
            } else if model.inputFocused {
                TouchControlsButton(area: area, showControls: model.showControls)
            }
            Color.clear.allowsHitTesting(false).accessibilityHidden(true)
                .onChange(of: area, initial: true) { _, area in
                    guard geometry.size.width > 0, geometry.size.height > 0 else { return }
                    model.touchGeometryChanged(usable: !TouchLayout().frames(in: area).isEmpty)
                }
        }
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
    var leftStick = false
    var preview = false
    let showControls: () -> Void

    var body: some View {
        ZStack {
            TouchGamepadRepresentation(capture: capture, layout: layout, area: area,
                                       mouseMode: mouseMode, leftStick: leftStick, preview: preview)
            if TouchLayout().frames(in: area).isEmpty {
                Text("Make this window larger to use touch controls.")
                    .font(.callout).padding().background(.regularMaterial, in: .capsule)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            TouchControlsButton(area: area, showControls: showControls)
        }
    }
}

private struct TouchControlsButton: View {
    let area: CGRect
    let showControls: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let frame = TouchLayout.menuFrame(in: area)
            Button("Show controls", systemImage: "ellipsis", action: showControls)
                .labelStyle(.iconOnly).buttonStyle(TouchMenuStyle())
                .position(x: min(frame.midX, geometry.size.width - 22),
                          y: min(frame.midY, geometry.size.height - 22))
        }
    }
}

private struct TouchMenuStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func makeBody(configuration: Configuration) -> some View {
        let colors = TouchAppearance.colors(style: colorScheme == .dark ? .dark : .light,
                                           contrast: contrast == .increased, opaque: reduceTransparency,
                                           pressed: configuration.isPressed)
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
    var capture: TouchGamepadCapture?
    let layout: TouchLayout
    let area: CGRect
    var mouseMode = false
    var leftStick = false
    var preview = false

    func makeUIView(context: Context) -> TouchGamepadView { TouchGamepadView() }

    func updateUIView(_ view: TouchGamepadView, context: Context) {
        view.configure(capture: capture, layout: layout, area: area, preview: preview)
        view.mouseMode(mouseMode, leftStick: leftStick)
    }
}
