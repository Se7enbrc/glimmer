// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import SwiftUI

struct ControllerLayoutDiagram: View {
    let family: ControllerDiagramFamily
    let controls: [ControllerLayoutControl]
    @State var rear = false
    var select: (ControllerLayoutControl) -> Void

    private var positioned: [(ControllerLayoutControl, ControllerDiagramPlacement)] {
        controls.compactMap { control in
            ControllerDiagramGeometry.placement(control, family: family).map { (control, $0) }
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            if positioned.contains(where: { $0.1.rear }) {
                Picker("Controller view", selection: $rear) {
                    Text("Front").tag(false)
                    Text("Back").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Controller view")
                .frame(maxWidth: 220)
            }
            GeometryReader { geometry in
                let scale = geometry.size.width / 480
                ZStack(alignment: .topLeading) {
                    shell
                    if !rear {
                        directionPad(scale: scale)
                        stick(left: true, scale: scale)
                        stick(left: false, scale: scale)
                    }
                    ForEach(positioned.filter { $0.1.rear == rear }, id: \.0.id) { control, placement in
                        controlButton(control, placement: placement, scale: scale)
                    }
                }
            }
            .aspectRatio(480.0 / 330, contentMode: .fit)
            .frame(maxWidth: 560)
            .environment(\.layoutDirection, .leftToRight)
            if controls.contains(where: { control in
                if case .extra = control.id { return ControllerDiagramGeometry.placement(control, family: family) == nil }
                return false
            }) {
                Text("Some button positions aren't provided by this controller. Use the list to edit them.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var shell: some View {
        GeometryReader { geometry in
            let scale = geometry.size.width / 480
            let body = ControllerBodyShape(family: family)
            body.fill(.regularMaterial)
                .overlay { body.stroke(.secondary.opacity(0.5), lineWidth: 1.5) }
            if family == .backbone {
                RoundedRectangle(cornerRadius: 12 * scale)
                    .fill(.background)
                    .overlay { RoundedRectangle(cornerRadius: 12 * scale).stroke(.tertiary, lineWidth: 1) }
                    .frame(width: 274 * scale, height: 170 * scale)
                    .position(x: 240 * scale, y: 177 * scale)
            }
            if rear {
                RoundedRectangle(cornerRadius: 8 * scale)
                    .stroke(.tertiary, lineWidth: 1)
                    .frame(width: (family.isPlayStation ? 54 : 92) * scale,
                           height: (family.isPlayStation ? 16 : 86) * scale)
                    .position(x: 240 * scale, y: (family.isPlayStation ? 216 : 144) * scale)
            }
        }
        .allowsHitTesting(false)
    }

    private func controlButton(_ control: ControllerLayoutControl, placement: ControllerDiagramPlacement,
                               scale: CGFloat) -> some View {
        let touchpad = control.id == .button(.touchpad)
        let radius = touchpad ? 8 * scale : min(placement.width, placement.height) * scale / 2
        let shape = RoundedRectangle(cornerRadius: radius)
        return Button { select(control) } label: {
            Image(systemName: control.symbol)
                .resizable().scaledToFit()
                .frame(width: min(placement.width - 6, touchpad ? 24 : 44) * scale,
                       height: min(placement.height - 6, 26) * scale)
                .frame(width: placement.width * scale, height: placement.height * scale)
                .foregroundStyle(.primary)
                .background(Color.primary.opacity(0.035), in: shape)
                .overlay {
                    if placement.rear || touchpad || family.isPlayStation {
                        shape.stroke(.secondary.opacity(0.35), lineWidth: 0.75)
                    }
                }
                .frame(minWidth: 28, minHeight: 28)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(control.name)
        .help(control.name)
        .position(x: placement.point.x * scale, y: placement.point.y * scale)
    }

    private func directionPad(scale: CGFloat) -> some View {
        let directions: [ControllerMappedButton] = [.up, .down, .left, .right]
        let available = controls.filter { control in directions.contains { control.id == .button($0) } }
        return Menu {
            ForEach(available) { control in Button(control.name) { select(control) } }
        } label: {
            Image(systemName: "dpad.fill")
                .resizable().scaledToFit().foregroundStyle(.secondary)
                .frame(width: 66 * scale, height: 66 * scale)
        }
        .buttonStyle(.plain).menuIndicator(.hidden)
        .disabled(available.isEmpty)
        .position(x: family.dpad.x * scale, y: family.dpad.y * scale)
    }

    private func stick(left: Bool, scale: CGFloat) -> some View {
        let axes: [ControllerMappedAxis] = left ? [.leftX, .leftY] : [.rightX, .rightY]
        let available = controls.filter { control in
            switch control.id {
            case .button(let button): button == (left ? .leftStick : .rightStick)
            case .axis(let axis), .direction(let axis, _): axes.contains(axis)
            default: false
            }
        }
        let point = left ? family.leftStick : family.rightStick
        return Menu {
            ForEach(available) { control in Button(control.name) { select(control) } }
        } label: {
            Circle().fill(.secondary.opacity(0.16))
                .overlay { Circle().stroke(.secondary.opacity(0.6), lineWidth: 1.5) }
                .overlay {
                    Circle().fill(.background).padding(7 * scale)
                        .overlay { Image(systemName: left ? "l.joystick.press.down" : "r.joystick.press.down")
                            .font(.system(size: 24 * scale)).foregroundStyle(.secondary) }
                }
                .frame(width: 66 * scale, height: 66 * scale)
        }
        .buttonStyle(.plain).menuIndicator(.hidden)
        .disabled(available.isEmpty)
        .position(x: point.x * scale, y: point.y * scale)
    }
}
