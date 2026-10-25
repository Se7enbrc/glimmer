// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import SwiftUI

struct ControllerShoulderArtwork: View {
    let family: ControllerDiagramFamily
    let control: ControllerLayoutControl
    let placement: ControllerDiagramPlacement
    let scale: CGFloat

    var body: some View {
        let trigger = ControllerShoulderGeometry.isTrigger(control.id)
        let bounds = ControllerShoulderGeometry.rawPath(family: family, trigger: trigger, rear: placement.rear).boundingRect
        let point = ControllerShoulderGeometry.labelPoint(family: family, trigger: trigger, rear: placement.rear)
        ControllerButtonShape(family: family, placement: placement, source: control.id)
            .stroke(style: StrokeStyle(lineWidth: 1.2 * scale, lineCap: .round, lineJoin: .round))
            .overlay(alignment: .topLeading) {
                Text(ControllerShoulderGeometry.legend(family: family, source: control.id))
                    .font(.caption2.weight(.medium))
                    .lineLimit(1).minimumScaleFactor(0.3)
                    .frame(width: 16 * scale, height: 8 * scale)
                    .position(x: (placement.point.x < 240 ? point.x - bounds.minX : bounds.maxX - point.x) * scale,
                              y: (point.y - bounds.minY) * scale)
            }
            .frame(width: placement.width * scale, height: placement.height * scale)
            .accessibilityHidden(true)
    }
}

struct ControllerShoulderButton: View {
    let family: ControllerDiagramFamily
    let control: ControllerLayoutControl
    let placement: ControllerDiagramPlacement
    let scale: CGFloat
    let selected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            ControllerShoulderArtwork(family: family, control: control, placement: placement, scale: scale)
                .contentShape(ControllerButtonShape(family: family, placement: placement, source: control.id))
        }
        .buttonStyle(ControllerShoulderButtonStyle(selected: selected))
        .accessibilityLabel(control.name)
        .help(control.name)
        .position(x: placement.point.x * scale, y: placement.point.y * scale)
    }
}

private struct ControllerShoulderButtonStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(selected || configuration.isPressed ? Color.accentColor : Color.primary)
    }
}

#if os(iOS)
struct ControllerShoulderMenu: View {
    let family: ControllerDiagramFamily
    let controls: [ControllerLayoutControl]
    let rear: Bool
    let left: Bool
    let scale: CGFloat
    let selected: ControllerLayoutSource?
    let select: (ControllerLayoutControl) -> Void

    private var available: [ControllerLayoutControl] {
        controls.filter { ControllerShoulderGeometry.isShoulder($0.id) && ControllerShoulderGeometry.isLeft($0.id) == left }
    }

    var body: some View {
        let frame = ControllerShoulderGeometry.targetFrame(family: family, left: left, rear: rear, scale: scale)
        Menu {
            ForEach(available) { control in
                Button(control.name) { select(control) }
            }
        } label: {
            ZStack(alignment: .topLeading) {
                ForEach(available) { control in
                    let placement = ControllerShoulderGeometry.placement(family: family, source: control.id, rear: rear)
                    ControllerShoulderArtwork(family: family, control: control, placement: placement, scale: scale)
                        .foregroundStyle(selected == control.id ? Color.accentColor : Color.primary)
                        .position(x: placement.point.x * scale - frame.minX, y: placement.point.y * scale - frame.minY)
                }
            }
            .frame(width: frame.width, height: frame.height)
            .contentShape(ControllerShoulderTarget(family: family, controls: available, rear: rear, left: left, scale: scale))
        }
        .buttonStyle(.plain).menuIndicator(.hidden)
        .disabled(available.isEmpty)
        .accessibilityLabel(left ? "Left shoulder buttons" : "Right shoulder buttons")
        .accessibilityValue(available.map(\.name).joined(separator: ", "))
        .position(x: frame.midX, y: frame.midY)
    }
}
#endif

struct ControllerShoulderTarget: Shape {
    let family: ControllerDiagramFamily
    let controls: [ControllerLayoutControl]
    let rear: Bool
    let left: Bool
    let scale: CGFloat

    func path(in rect: CGRect) -> Path {
        let frame = ControllerShoulderGeometry.targetFrame(family: family, left: left, rear: rear, scale: scale)
        var path = Path(ControllerShoulderGeometry.targetCore(family: family, left: left, rear: rear, scale: scale))
        for control in controls {
            let placement = ControllerShoulderGeometry.placement(family: family, source: control.id, rear: rear)
            let bounds = placement.bounds.applying(.init(scaleX: scale, y: scale))
            path = path.union(ControllerButtonShape(family: family, placement: placement, source: control.id).path(in: bounds))
        }
        return path.applying(.init(translationX: -frame.minX, y: -frame.minY))
            .applying(.init(scaleX: rect.width / frame.width, y: rect.height / frame.height))
            .applying(.init(translationX: rect.minX, y: rect.minY))
    }
}
