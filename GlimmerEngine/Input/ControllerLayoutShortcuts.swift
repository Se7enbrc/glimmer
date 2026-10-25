// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

public struct ControllerLayoutShortcuts: Codable, Equatable, Sendable {
    public static let fixedStop: Set<ControllerLayoutSource> = [
        .button(.leftShoulder), .button(.rightShoulder), .button(.menu), .button(.options)
    ]

    public var stop: Set<ControllerLayoutSource>

    public init(stop: Set<ControllerLayoutSource> = []) { self.stop = stop }

    public static func escape(available: Set<ControllerLayoutSource>) -> Set<ControllerLayoutSource> {
        let pairs: [[ControllerMappedButton]] = [[.menu, .options], [.menu, .leftStick], [.leftStick, .rightStick]]
        return pairs.map { Set($0.map { ControllerLayoutSource.button($0) }) }
            .first { $0.isSubset(of: available) } ?? []
    }

    public func validate(available: Set<ControllerLayoutSource>) throws {
        guard stop.isEmpty || (stop.count >= 2 && stop.count <= 8 && stop.isSubset(of: available)) else {
            throw ControllerLayoutError.invalidBindings
        }
        guard stop.allSatisfy({ source in
            switch source {
            case .button, .trigger, .extra: true
            case .axis, .direction: false
            }
        }) else { throw ControllerLayoutError.invalidBindings }
        let escape = Self.escape(available: available)
        if !stop.isEmpty, stop.isSubset(of: escape) { throw ControllerLayoutError.invalidBindings }
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
