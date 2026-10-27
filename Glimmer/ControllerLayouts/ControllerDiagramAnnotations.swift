// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import SwiftUI

struct ControllerDiagramAnnotation: Identifiable {
    let action: ControllerMouseAction
    let sources: Set<ControllerLayoutSource>
    var id: ControllerMouseAction { action }

    static func mouse(_ bindings: ControllerMouseBindings) -> [Self] {
        ControllerMouseAction.allCases.compactMap { action in
            let sources = bindings[action]
            return sources.isEmpty ? nil : Self(action: action, sources: sources)
        }
    }

    func points(controls: [ControllerLayoutControl], family: ControllerDiagramFamily, rear: Bool) -> [CGPoint] {
        var points: [CGPoint] = []
        for control in controls where sources.contains(control.id) {
            let point: CGPoint?
            switch control.id {
            case .axis(.leftX), .axis(.leftY), .button(.leftStick): point = rear ? nil : family.leftStick
            case .axis(.rightX), .axis(.rightY), .button(.rightStick): point = rear ? nil : family.rightStick
            default: point = ControllerDiagramGeometry.visiblePlacement(control, family: family, rear: rear)?.point
            }
            if let point, !points.contains(point) { points.append(point) }
        }
        return points
    }
}

struct ControllerDiagramAnnotationRail: View {
    let annotations: [ControllerDiagramAnnotation]
    let controls: [ControllerLayoutControl]
    let family: ControllerDiagramFamily
    let rear: Bool
    let above: Bool
    let focused: Set<ControllerLayoutSource>
    @ScaledMetric(relativeTo: .caption) private var textSize = 13.0
    @ScaledMetric(relativeTo: .caption) private var rowHeight = 24.0

    private var visible: [(ControllerDiagramAnnotation, [CGPoint])] {
        annotations.compactMap { item in
            let points = item.points(controls: controls, family: family, rear: rear)
            guard let first = points.first, (first.y < 155) == above else { return nil }
            return (item, points)
        }
    }

    var body: some View {
        let left = visible.filter { $0.1[0].x < 240 }
        let right = visible.filter { $0.1[0].x >= 240 }
        let height = Double(max(left.count, right.count)) * rowHeight
        if height > 0 {
            GeometryReader { geometry in
                let scale = geometry.size.width / 480
                ForEach([false, true], id: \.self) { rightSide in
                    let items = rightSide ? right : left
                    ForEach(Array(items.enumerated()), id: \.element.0.id) { index, item in
                        let selected = !item.0.sources.isDisjoint(with: focused)
                        let y = Double(index) * rowHeight + rowHeight / 2
                        let x = geometry.size.width * (rightSide ? 0.75 : 0.25)
                        Path { path in
                            for point in item.1 {
                                path.move(to: CGPoint(x: x, y: y + (above ? rowHeight / 2 : -rowHeight / 2)))
                                path.addLine(to: CGPoint(x: point.x * scale,
                                    y: above ? height + 12 + point.y * scale : (point.y - 330) * scale - 12))
                            }
                        }
                        .stroke(Color.accentColor.opacity(selected ? 0.7 : 0.3), lineWidth: selected ? 1.5 : 0.75)
                        .allowsHitTesting(false).accessibilityHidden(true)
                        Text(item.0.action.title)
                            .font(.system(size: textSize, weight: selected ? .semibold : .regular))
                            .foregroundStyle(selected ? Color.accentColor : Color.primary)
                            .frame(width: geometry.size.width / 2 - 8, height: rowHeight)
                            .position(x: x, y: y)
                    }
                }
            }
            .frame(height: height)
            .allowsHitTesting(false)
        }
    }
}
