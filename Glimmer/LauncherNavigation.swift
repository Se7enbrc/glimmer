// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import SwiftUI

enum LauncherFocus: Hashable {
    case app(Int), pc, overflow, state
}

enum LauncherCommand: Equatable {
    case up, down, left, right, activate, dismiss

    static func direction(x: Float, y: Float) -> Self? {
        guard max(abs(x), abs(y)) >= 0.55 else { return nil }
        if abs(x) > abs(y) { return x > 0 ? .right : .left }
        return y > 0 ? .up : .down
    }

    var key: (code: UInt16, characters: String) {
        switch self {
        case .up: (126, "\u{F700}")
        case .down: (125, "\u{F701}")
        case .left: (123, "\u{F702}")
        case .right: (124, "\u{F703}")
        case .activate: (49, " ")
        case .dismiss: (53, "\u{1B}")
        }
    }
}

struct LauncherControllerInput {
    var direction: LauncherCommand?
    var activate = false
    var dismiss = false

    var isNeutral: Bool { direction == nil && !activate && !dismiss }
}

struct LauncherControllerRepeat {
    private var prior = LauncherControllerInput()
    private var nextRepeat = TimeInterval.infinity
    private var armed = false

    mutating func commands(_ input: LauncherControllerInput, at time: TimeInterval) -> [LauncherCommand] {
        // Require release after a window/stream handoff so a held game button cannot launch another app.
        guard armed else {
            armed = input.isNeutral
            prior = input
            return []
        }
        var result: [LauncherCommand] = []
        if input.dismiss && !prior.dismiss { result.append(.dismiss) }
        if input.activate && !prior.activate && !input.dismiss { result.append(.activate) }
        if let direction = input.direction {
            if direction != prior.direction {
                result.append(direction)
                nextRepeat = time + 0.4
            } else if time >= nextRepeat {
                result.append(direction)
                nextRepeat = time + 0.12
            }
        } else {
            nextRepeat = .infinity
        }
        prior = input
        return result
    }
}

enum LauncherNavigation {
    static func isEnabled(streaming: Bool, testing: Bool, active: Bool, launcherKey: Bool, sheetKey: Bool) -> Bool {
        !streaming && !testing && active && (launcherKey || sheetKey)
    }

    static func destination(from focus: LauncherFocus?, command: LauncherCommand,
                            cells: [LauncherFocus], columns: Int, hasSwitcher: Bool) -> LauncherFocus? {
        guard command != .activate, command != .dismiss else { return focus }
        guard !cells.isEmpty else { return hasSwitcher ? .pc : nil }
        if focus == .pc { return command == .down ? cells.first : .pc }
        guard let focus, let index = cells.firstIndex(of: focus) else { return cells.first }
        if focus == .state {
            return command == .up ? cells.last(where: { $0 != .state }) ?? (hasSwitcher ? .pc : .state) : .state
        }
        let grid = cells.filter { $0 != .state }
        let columns = max(1, columns)
        switch command {
        case .up:
            return index < columns ? (hasSwitcher ? .pc : focus) : grid[index - columns]
        case .down:
            guard index / columns < (grid.count - 1) / columns else {
                return cells.contains(.state) ? .state : focus
            }
            return grid[min(index + columns, grid.count - 1)]
        case .left:
            return index % columns == 0 ? focus : grid[index - 1]
        case .right:
            return (index + 1) % columns == 0 ? focus : grid[min(index + 1, grid.count - 1)]
        case .activate, .dismiss: return focus
        }
    }
}

struct LauncherFocusCells: PreferenceKey {
    static let defaultValue: [LauncherFocus] = []

    static func reduce(value: inout [LauncherFocus], nextValue: () -> [LauncherFocus]) {
        value.append(contentsOf: nextValue())
    }
}
