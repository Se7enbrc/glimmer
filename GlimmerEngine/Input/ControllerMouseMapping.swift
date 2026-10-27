// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

public enum ControllerMouseMapping: String, CaseIterable, Codable, Sendable {
    case rightStick = "right", leftStick = "left"

    public var title: String { self == .rightStick ? "Right-handed" : "Left-handed" }

    public func sources(for action: ControllerMouseAction) -> Set<ControllerLayoutSource> {
        let right = self == .rightStick
        switch action {
        case .pointer: return Self.stick(right: right)
        case .scroll: return Self.stick(right: !right)
        case .primary: return [.trigger(right ? .right : .left)]
        case .secondary: return [.button(right ? .rightShoulder : .leftShoulder)]
        case .middle: return [.button(right ? .rightStick : .leftStick)]
        case .back: return [.trigger(right ? .left : .right)]
        case .forward: return [.button(right ? .leftShoulder : .rightShoulder)]
        case .toggle: return [.button(.menu)]
        }
    }

    public static func modeMessage(enabled: Bool, controller: String = "Controller") -> String {
        enabled ? "\(controller) is now a mouse." : "\(controller) is back in the game."
    }

    /// The symbol every platform shows beside `modeMessage`.
    public static func modeSymbol(enabled: Bool) -> String {
        enabled ? "computermouse.fill" : "gamecontroller.fill"
    }

    public static func stick(right: Bool) -> Set<ControllerLayoutSource> {
        right ? [.axis(.rightX), .axis(.rightY)] : [.axis(.leftX), .axis(.leftY)]
    }
}

public enum ControllerMouseAction: String, CaseIterable, Codable, Identifiable, Sendable {
    case pointer, scroll, primary, secondary, middle, back, forward, toggle
    public var id: Self { self }
    public var isStick: Bool { self == .pointer || self == .scroll }
    public var title: String {
        switch self {
        case .pointer: "Pointer stick"
        case .scroll: "Scroll stick"
        case .primary: "Primary click"
        case .secondary: "Secondary click"
        case .middle: "Middle click"
        case .back: "Back"
        case .forward: "Forward"
        case .toggle: "Mouse-mode toggle"
        }
    }
}

public struct ControllerMouseBindings: Codable, Equatable, Sendable {
    public var preset: ControllerMouseMapping
    public private(set) var overrides: [ControllerMouseAction: Set<ControllerLayoutSource>]
    public var isCustom: Bool { !overrides.isEmpty }
    public var title: String { isCustom ? "Custom" : preset.title }

    public init(preset: ControllerMouseMapping = .rightStick,
                overrides: [ControllerMouseAction: Set<ControllerLayoutSource>] = [:]) {
        self.preset = preset
        self.overrides = overrides
    }

    public static func load(from defaults: UserDefaults) -> Self {
        if let data = defaults.data(forKey: "controllerMouseBindings"),
           let saved = try? JSONDecoder().decode(Self.self, from: data) { return saved }
        return Self(preset: defaults.string(forKey: "controllerMouseStick") == "left" ? .leftStick : .rightStick)
    }

    public func save(to defaults: UserDefaults) throws {
        defaults.set(try JSONEncoder().encode(self), forKey: "controllerMouseBindings")
        defaults.set(preset.rawValue, forKey: "controllerMouseStick")
    }

    public subscript(action: ControllerMouseAction) -> Set<ControllerLayoutSource> {
        if let custom = overrides[action] { return custom }
        let sources = preset.sources(for: action)
        // A changed preset cannot take a control away from an explicit recording.
        return overrides.values.contains { Self.overlaps($0, sources) } ? [] : sources
    }

    public func resolving(_ shortcuts: ControllerLayoutShortcuts) -> Self {
        var resolved = self
        for action in ControllerMouseAction.allCases where overrides[action] == nil {
            if [shortcuts.stop, shortcuts.stats].contains(self[action]) {
                resolved.assign([], to: action)
            }
        }
        return resolved
    }

    public mutating func assign(_ sources: Set<ControllerLayoutSource>, to action: ControllerMouseAction) {
        overrides[action] = sources
    }

    public func recordingProblem(_ sources: Set<ControllerLayoutSource>, for action: ControllerMouseAction,
                                 available: Set<ControllerLayoutSource>, shortcuts: [ControllerLayoutShortcuts]) -> String? {
        if action.isStick {
            let sticks = [ControllerMouseMapping.stick(right: true), ControllerMouseMapping.stick(right: false)]
            guard sources.isEmpty || sticks.contains(sources)
            else { return "Choose a stick." }
        } else if sources.count > 8 || !sources.allSatisfy(\.isMouseButton) {
            return "Choose shoulders, triggers, stick buttons or other controller buttons."
        }
        guard sources.isSubset(of: available) else { return "Choose controls available on this controller." }
        for other in ControllerMouseAction.allCases where other != action && Self.overlaps(sources, self[other]) {
            return "Already used for \(other.title). Change that binding first."
        }
        for shortcut in shortcuts where Self.overlaps(sources, shortcut.stop) || Self.overlaps(sources, shortcut.stats) {
            return "Choose a binding that doesn't contain a Glimmer shortcut, or fit inside it."
        }
        return nil
    }

    public static func overlaps(_ first: Set<ControllerLayoutSource>, _ second: Set<ControllerLayoutSource>) -> Bool {
        !first.isEmpty && !second.isEmpty && (first.isSubset(of: second) || second.isSubset(of: first))
    }
}

extension ControllerLayoutSource {
    public var isMouseButton: Bool {
        switch self {
        case .button(.a), .button(.b), .button(.x), .button(.y): false
        default: isChordButton
        }
    }
}
