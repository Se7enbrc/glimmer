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
    static let defaultOpacity = 0.2
    static let opacityRange = 0.1...0.6
    private var storedOpacity = defaultOpacity
    var changes: [TouchElement: Placement] = [:]
    var opacity: Double {
        get { storedOpacity }
        set { storedOpacity = Self.boundedOpacity(newValue) }
    }

    private enum CodingKeys: String, CodingKey { case changes, storedOpacity = "opacity" }

    init() {}

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        changes = try values.decode([TouchElement: Placement].self, forKey: .changes)
        opacity = try values.decodeIfPresent(Double.self, forKey: .storedOpacity) ?? Self.defaultOpacity
    }

    static func boundedOpacity(_ value: Double) -> Double {
        guard value.isFinite else { return defaultOpacity }
        return (min(opacityRange.upperBound, max(opacityRange.lowerBound, value)) * 20).rounded() / 20
    }

    static func family(in area: CGRect) -> Family { area.height >= 500 && area.width >= 740 ? .expanded : .compact }

    static func defaults(in area: CGRect) -> [TouchElement: Placement] {
        let expanded = family(in: area) == .expanded
        let outer = expanded ? 100.0 : 72.0
        // Narrow phones pull the d-pad and right stick inward so Options and Menu keep the bottom center.
        let inner = expanded ? 254.0 : min(214, max(194, area.width / 2 - 124))
        let lower = expanded ? 118.0 : 80.0
        let upper = expanded ? 266.0 : 188.0
        let face = expanded ? 60.0 : 54.0
        let menuBottom = area.width < (expanded ? 756 : 636) ? area.height - 30 : 30
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

    func editing(_ element: TouchElement, to placement: Placement, in area: CGRect) -> TouchLayout? {
        var edited = editable(in: area)
        guard edited.accepts(element, placement: placement, in: area) else { return nil }
        edited.changes[element] = placement
        return edited
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

    /// The free rectangle that best fits `target`. Among those that fit it whole, the one nearest
    /// `anchor` wins, so an overlay keeps its usual corner whenever that corner is clear.
    static func clearArea(in bounds: CGRect, avoiding controls: [CGRect], target: CGSize,
                          anchor: CGPoint? = nil) -> CGRect {
        let obstacles = controls.map { $0.insetBy(dx: -8, dy: -8).intersection(bounds) }.filter { !$0.isNull }
        let edges = Set([bounds.minX, bounds.maxX] + obstacles.flatMap { [$0.minX, $0.maxX] }).sorted()
        var best = CGRect.zero
        var score: CGFloat = 0
        var distance = CGFloat.infinity
        for (index, left) in edges.enumerated() {
            for right in edges.dropFirst(index + 1) {
                let blocked = obstacles.filter { $0.minX < right && $0.maxX > left }.sorted { $0.minY < $1.minY }
                var top = bounds.minY
                for block in blocked + [CGRect(x: left, y: bounds.maxY, width: right - left, height: 0)] {
                    let gap = CGRect(x: left, y: top, width: right - left, height: max(0, block.minY - top))
                    let fit = min(gap.width / target.width, gap.height / target.height)
                    let away = anchor.map { hypot(max(gap.minX - $0.x, 0, $0.x - gap.maxX),
                                                  max(gap.minY - $0.y, 0, $0.y - gap.maxY)) } ?? 0
                    if fit >= 1 && anchor != nil ? score < 1 || away < distance : fit > score {
                        best = gap; score = fit; distance = away
                    }
                    top = max(top, block.maxY)
                }
            }
        }
        return best
    }
}
