// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import UIKit

struct TouchLayout: Codable, Equatable {
    struct Placement: Codable, Equatable {
        var edge: Double
        var bottom: Double
        var scale: Double = 1
        var hidden = false
        var valid: Bool {
            edge.isFinite && bottom.isFinite && scale.isFinite && edge >= 0 && bottom >= 0
                && (0.75...1.5).contains(scale)
        }
    }
    enum Family: String, Codable { case compact, expanded }
    var changes: [TouchElement: Placement] = [:]

    static func family(in area: CGRect) -> Family { area.height >= 500 && area.width >= 740 ? .expanded : .compact }

    static func defaults(in area: CGRect) -> [TouchElement: Placement] {
        let expanded = family(in: area) == .expanded
        let outer = expanded ? 100.0 : 72.0
        let inner = expanded ? 254.0 : 214.0
        let lower = expanded ? 118.0 : 80.0
        let upper = expanded ? 266.0 : 188.0
        let face = expanded ? 60.0 : 54.0
        let menuBottom = area.width < (expanded ? 756 : 680) ? area.height - 30 : 30
        return [
            .leftStick: .init(edge: outer, bottom: upper), .rightStick: .init(edge: inner, bottom: lower),
            .dpad: .init(edge: inner, bottom: lower),
            .a: .init(edge: outer, bottom: upper - face), .y: .init(edge: outer, bottom: upper + face),
            .x: .init(edge: outer + face, bottom: upper), .b: .init(edge: outer - face, bottom: upper),
            .leftTrigger: .init(edge: outer - 6, bottom: upper + 120),
            .rightTrigger: .init(edge: outer - 6, bottom: upper + 120),
            .leftShoulder: .init(edge: outer + 80, bottom: upper + 120),
            .rightShoulder: .init(edge: outer + 80, bottom: upper + 120),
            .leftStickButton: .init(edge: outer, bottom: lower - 28),
            .rightStickButton: .init(edge: outer, bottom: lower - 28),
            .options: .init(edge: area.width / 2 - 28, bottom: menuBottom),
            .menu: .init(edge: area.width / 2 - 28, bottom: menuBottom)
        ]
    }

    func placement(_ element: TouchElement, in area: CGRect) -> Placement {
        changes[element] ?? Self.defaults(in: area)[element] ?? .init(edge: 72, bottom: 80)
    }

    func frames(in area: CGRect) -> [TouchElement: CGRect] {
        let result = rawFrames(in: area)
        if changes.isEmpty { return result }
        let defaults = TouchLayout().frames(in: area)
        let menu = Self.menuFrame(in: area)
        let collides = result.contains { element, frame in
            menu.intersects(frame.insetBy(dx: -7.9, dy: -7.9))
                || result.contains { $0.key != element && $0.value.intersects(frame.insetBy(dx: -7.9, dy: -7.9)) }
        }
        // A smaller window can invalidate an otherwise valid saved layout without changing its stored positions.
        if collides { return defaults.filter { !placement($0.key, in: area).hidden } }
        return result
    }

    func accepts(_ element: TouchElement, placement: Placement, in area: CGRect) -> Bool {
        guard placement.valid else { return false }
        var proposed = self
        proposed.changes[element] = placement
        let frames = proposed.rawFrames(in: area)
        guard let frame = frames[element] else { return placement.hidden }
        guard !Self.menuFrame(in: area).intersects(frame.insetBy(dx: -8, dy: -8)) else { return false }
        return frames.allSatisfy { $0.key == element || !$0.value.intersects(frame.insetBy(dx: -8, dy: -8)) }
    }

    static func menuFrame(in area: CGRect) -> CGRect {
        let frames = TouchLayout().rawFrames(in: area)
        let centers = [CGPoint(x: area.maxX - 24, y: area.minY + 24),
                       CGPoint(x: area.midX, y: area.minY + 24), CGPoint(x: area.midX, y: area.minY + 82)]
        for center in centers {
            let frame = CGRect(x: center.x - 22, y: center.y - 22, width: 44, height: 44)
            if frames.values.allSatisfy({ !$0.intersects(frame.insetBy(dx: -7.9, dy: -7.9)) }) { return frame }
        }
        return CGRect(x: area.midX - 22, y: area.minY + 60, width: 44, height: 44)
    }

    func editable(in area: CGRect) -> TouchLayout {
        var result = self
        for (element, frame) in frames(in: area) {
            let normal = element.size(expanded: Self.family(in: area) == .expanded)
            result.changes[element] = Placement(
                edge: element.isLeft ? frame.midX - area.minX : area.maxX - frame.midX,
                bottom: area.maxY - frame.midY, scale: frame.width / normal.width)
        }
        return result
    }

    private func rawFrames(in area: CGRect) -> [TouchElement: CGRect] {
        guard area.width >= 590, area.height >= 330 else { return [:] }
        let expanded = Self.family(in: area) == .expanded
        var result: [TouchElement: CGRect] = [:]
        for element in TouchElement.allCases {
            let placement = placement(element, in: area)
            guard !placement.hidden else { continue }
            let size = element.size(expanded: expanded)
            let minimum: CGFloat = element == .dpad ? 132 : 44
            let width = max(minimum, size.width * placement.scale)
            let height = max(minimum, size.height * placement.scale)
            let x = element.isLeft ? area.minX + placement.edge : area.maxX - placement.edge
            let y = area.maxY - placement.bottom
            result[element] = CGRect(x: min(max(x - width / 2, area.minX), area.maxX - width),
                                     y: min(max(y - height / 2, area.minY), area.maxY - height),
                                     width: width, height: height)
        }
        return result
    }

    static func playableArea(_ safe: CGRect, avoiding regions: [CGRect]) -> CGRect {
        var area = safe
        for region in regions where area.intersects(region) {
            if region.width >= area.width * 0.5 {
                area = CGRect(x: area.minX, y: max(area.minY, region.maxY), width: area.width,
                              height: max(0, area.maxY - region.maxY))
            } else {
                let left = CGRect(x: area.minX, y: area.minY,
                                  width: max(0, region.minX - area.minX), height: area.height)
                let right = CGRect(x: region.maxX, y: area.minY,
                                   width: max(0, area.maxX - region.maxX), height: area.height)
                area = left.width >= right.width ? left : right
            }
        }
        return area
    }
}
