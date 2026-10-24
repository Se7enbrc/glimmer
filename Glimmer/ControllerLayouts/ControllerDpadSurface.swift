// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import SwiftUI

struct ControllerDpadCross: Shape {
    func path(in rect: CGRect) -> Path {
        let points: [CGPoint] = [
            .init(x: 0.36, y: 0.02), .init(x: 0.64, y: 0.02), .init(x: 0.64, y: 0.36),
            .init(x: 0.98, y: 0.36), .init(x: 0.98, y: 0.64), .init(x: 0.64, y: 0.64),
            .init(x: 0.64, y: 0.98), .init(x: 0.36, y: 0.98), .init(x: 0.36, y: 0.64),
            .init(x: 0.02, y: 0.64), .init(x: 0.02, y: 0.36), .init(x: 0.36, y: 0.36)
        ]
        return Path { path in
            let radius: CGFloat = 0.065
            for index in points.indices {
                let previous = points[(index + points.count - 1) % points.count]
                let point = points[index]
                let next = points[(index + 1) % points.count]
                let before = CGPoint(x: point.x + (previous.x - point.x).sign * radius,
                                     y: point.y + (previous.y - point.y).sign * radius)
                let after = CGPoint(x: point.x + (next.x - point.x).sign * radius,
                                    y: point.y + (next.y - point.y).sign * radius)
                if index == 0 { path.move(to: before) } else { path.addLine(to: before) }
                path.addQuadCurve(to: after, control: point)
            }
            path.closeSubpath()
        }
        .applying(.init(scaleX: rect.width, y: rect.height))
        .applying(.init(translationX: rect.minX, y: rect.minY))
    }
}

struct ControllerDpadFacets: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.addRect(CGRect(x: rect.minX + rect.width / 3, y: rect.minY,
                                width: rect.width / 3, height: rect.height / 3))
            path.addRect(CGRect(x: rect.minX, y: rect.minY + rect.height / 3,
                                width: rect.width / 3, height: rect.height / 3))
            path.addRect(CGRect(x: rect.minX + rect.width * 2 / 3, y: rect.minY + rect.height / 3,
                                width: rect.width / 3, height: rect.height / 3))
            path.addRect(CGRect(x: rect.minX + rect.width / 3, y: rect.minY + rect.height * 2 / 3,
                                width: rect.width / 3, height: rect.height / 3))
        }
    }
}

private extension CGFloat {
    var sign: CGFloat { self == 0 ? 0 : self > 0 ? 1 : -1 }
}
