// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

public struct ControllerLayoutShortcuts: Codable, Equatable, Sendable {
    public static let fixedStop: Set<ControllerLayoutSource> = [
        .button(.leftShoulder), .button(.rightShoulder), .button(.menu), .button(.options)
    ]

    public static let defaultStats: Set<ControllerLayoutSource> = [
        .button(.options), .button(.leftStick), .button(.rightStick)
    ]
    public var stop: Set<ControllerLayoutSource>
    public var stats: Set<ControllerLayoutSource>

    public init(stop: Set<ControllerLayoutSource> = Self.fixedStop,
                stats: Set<ControllerLayoutSource> = Self.defaultStats) {
        self.stop = stop
        self.stats = stats
    }

    private enum CodingKeys: String, CodingKey { case stop, stats }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        stop = try values.decode(Set<ControllerLayoutSource>.self, forKey: .stop)
        stats = try values.decodeIfPresent(Set<ControllerLayoutSource>.self, forKey: .stats) ?? Self.defaultStats
    }

    public subscript(action: ControllerShortcutAction) -> Set<ControllerLayoutSource> {
        get { action == .stop ? stop : stats }
        set { if action == .stop { stop = newValue } else { stats = newValue } }
    }

    public func recordingProblem(for action: ControllerShortcutAction,
                                 available: Set<ControllerLayoutSource>) -> String? {
        let chord = self[action]
        guard chord.count >= 3 else { return "Choose at least three buttons." }
        guard chord.count <= 8, chord.isSubset(of: available), chord.allSatisfy(\.isChordButton) else {
            return "Choose buttons available on this controller."
        }
        let other = self[action == .stop ? .stats : .stop]
        if !other.isEmpty, chord.isSubset(of: other) || other.isSubset(of: chord) {
            return "Choose a shortcut that doesn't contain the other Glimmer shortcut, or fit inside it."
        }
        return nil
    }

    public static func savedGlobal(in defaults: UserDefaults) -> Self? {
        guard let raw = defaults.string(forKey: "controllerQuitChord"),
              let preset = ControllerQuitChord(rawValue: raw) else { return nil }
        let buttons: Set<ControllerButton>
        switch preset {
        case .none: buttons = []
        case .startSelectL1R1: return Self()
        case .l1r1: buttons = [.l1, .r1]
        case .l1r1l2r2: buttons = [.l1, .r1, .l2, .r2]
        case .l3r3: buttons = [.l3, .r3]
        case .custom:
            guard let data = defaults.data(forKey: "customControllerChord"),
                  let saved = try? JSONDecoder().decode(Set<ControllerButton>.self, from: data) else { return nil }
            buttons = saved
        }
        var sources = Set(ControllerMappedButton.allCases.filter { button in
            !heldControllerButtons(buttons: Int32(bitPattern: button.rawValue), leftTrigger: 0, rightTrigger: 0)
                .isDisjoint(with: buttons)
        }.map { ControllerLayoutSource.button($0) })
        if buttons.contains(.l2) { sources.insert(.trigger(.left)) }
        if buttons.contains(.r2) { sources.insert(.trigger(.right)) }
        return Self(stop: sources)
    }

    public var hasConflict: Bool {
        !stop.isEmpty && !stats.isEmpty && (stop.isSubset(of: stats) || stats.isSubset(of: stop))
    }

    public static func warning(for chord: Set<ControllerLayoutSource>) -> String? {
        let pairs: [Set<ControllerLayoutSource>] = [
            [.button(.leftStick), .button(.rightStick)],
            [.button(.leftShoulder), .button(.rightShoulder)],
            [.button(.menu), .button(.options)]
        ]
        guard pairs.contains(where: { $0.isSubset(of: chord) }) else { return nil }
        return "Some games use these buttons together. The PC sees them until the hold completes."
    }

    public static func escape(available: Set<ControllerLayoutSource>) -> Set<ControllerLayoutSource> {
        let pairs: [[ControllerMappedButton]] = [[.menu, .options], [.menu, .leftStick], [.leftStick, .rightStick]]
        return pairs.map { Set($0.map { ControllerLayoutSource.button($0) }) }
            .first { $0.isSubset(of: available) } ?? []
    }

    public func validate(available: Set<ControllerLayoutSource>) throws {
        // Older recordings remain stored; only new recordings must meet the stricter input rules.
        for chord in [stop, stats] {
            let buttons = chord.allSatisfy { source in
                switch source {
                case .button, .trigger, .extra: true
                case .axis, .direction: false
                }
            }
            let supported = chord.isSubset(of: available) || chord == Self.fixedStop || chord == Self.defaultStats
            guard chord.count <= 8, buttons, supported else { throw ControllerLayoutError.invalidBindings }
        }
        guard available.count <= 256 else { throw ControllerLayoutError.invalidBindings }
    }
}

public struct ControllerPhysicalChord: Sendable {
    public let buttons: UInt32
    public let triggers: UInt8
    public let extras: SIMD2<UInt64>

    public static let empty = ControllerPhysicalChord()

    private init() {
        buttons = 0
        triggers = 0
        extras = .zero
    }

    public init(sources: Set<ControllerLayoutSource>, extras: [String]) throws {
        guard extras.count <= 128 else { throw ControllerLayoutError.invalidBindings }
        var buttons: UInt32 = 0
        var triggers: UInt8 = 0
        var extraMask = SIMD2<UInt64>.zero
        for source in sources {
            switch source {
            case .button(let button): buttons |= button.rawValue
            case .trigger(let trigger): triggers |= 1 << trigger.rawValue
            case .extra(let name):
                guard let index = extras.firstIndex(of: name) else { throw ControllerLayoutError.invalidBindings }
                extraMask[index / 64] |= 1 << (index % 64)
            case .axis, .direction: throw ControllerLayoutError.invalidBindings
            }
        }
        self.buttons = buttons
        self.triggers = triggers
        self.extras = extraMask
    }

    public init(sample: ControllerMappingSample) {
        buttons = sample.buttons
        triggers = (sample.analog[0] > 0 ? 1 : 0) | (sample.analog[1] > 0 ? 2 : 0)
        extras = sample.extras
    }

    public func removing(from sample: ControllerMappingSample) -> ControllerMappingSample {
        var result = sample
        result.buttons &= ~buttons
        result.extras &= ~extras
        if triggers & 1 != 0 { result.analog[0] = 0 }
        if triggers & 2 != 0 { result.analog[1] = 0 }
        return result
    }

    public func released(in sample: ControllerMappingSample) -> Bool {
        sample.buttons & buttons == 0 && sample.extras & extras == .zero
            && (triggers & 1 == 0 || sample.analog[0] < 51) && (triggers & 2 == 0 || sample.analog[1] < 51)
    }

    public func held(in sample: ControllerMappingSample, exact: Bool = false) -> Bool {
        guard buttons != 0 || triggers != 0 || extras != .zero else { return false }
        let pressedTriggers: UInt8 = (sample.analog[0] >= 128 ? 1 : 0) | (sample.analog[1] >= 128 ? 2 : 0)
        if exact { return sample.buttons == buttons && pressedTriggers == triggers && sample.extras == extras }
        return sample.buttons & buttons == buttons && pressedTriggers & triggers == triggers
            && sample.extras & extras == extras
    }
}

public struct ControllerEscapeGesture: Sendable {
    public let chord: ControllerPhysicalChord
    private var began: TimeInterval?
    private var awaitingRelease = false
    private var cancelled = false

    public init(chord: ControllerPhysicalChord) { self.chord = chord }

    public mutating func reset() {
        began = nil
        awaitingRelease = false
        cancelled = false
    }

    public mutating func update(_ sample: ControllerMappingSample, at now: TimeInterval) -> Bool {
        guard now.isFinite else { reset(); return false }
        let neutral = sample.buttons == 0 && sample.extras == .zero && sample.analog[0] < 128 && sample.analog[1] < 128
        if cancelled {
            if neutral { reset() }
            return false
        }
        if chord.held(in: sample, exact: true) {
            if began == nil { began = now }
            return false
        }
        guard let began else { return false }
        let onlyChordButtons = sample.buttons & ~chord.buttons == 0 && sample.extras & ~chord.extras == .zero
        let noOtherTriggers = (chord.triggers & 1 != 0 || sample.analog[0] < 128)
            && (chord.triggers & 2 != 0 || sample.analog[1] < 128)
        guard onlyChordButtons, noOtherTriggers, now >= began, awaitingRelease || now - began >= 1 else {
            reset()
            cancelled = !neutral
            return false
        }
        awaitingRelease = true
        if neutral { reset(); return true }
        return false
    }

    public var isPending: Bool { began != nil }
}

public enum ControllerShortcutAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case stop, stats
    public var id: Self { self }
    public var title: String { self == .stop ? "Stop streaming" : "Stats" }
}

extension ControllerLayoutSource {
    public var isChordButton: Bool {
        switch self {
        case .button(.home): false
        case .button, .trigger, .extra: true
        case .axis, .direction: false
        }
    }
}
