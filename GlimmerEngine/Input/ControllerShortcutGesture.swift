// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

public struct ControllerShortcutGesture: Sendable {
    public static let holdSeconds = 0.4
    private let stop: ControllerPhysicalChord
    private let stats: ControllerPhysicalChord
    private var candidate: ControllerShortcutAction?
    public private(set) var deadline: TimeInterval?
    public private(set) var latched: ControllerShortcutAction?
    private var lastTime: TimeInterval = 0

    public init(stop: ControllerPhysicalChord, stats: ControllerPhysicalChord) {
        self.stop = stop
        self.stats = stats
    }

    public mutating func reset() {
        candidate = nil
        deadline = nil
        latched = nil
        lastTime = 0
    }

    public var suppressing: ControllerPhysicalChord? {
        (latched ?? candidate).map { $0 == .stop ? stop : stats }
    }

    public mutating func update(_ sample: ControllerMappingSample, at now: TimeInterval) -> ControllerShortcutAction? {
        guard now.isFinite else { reset(); return nil }
        // A hold timer can overtake a queued native report without ending the physical hold.
        let now = max(now, lastTime)
        lastTime = now
        if let deadline, now >= deadline, let candidate {
            latched = candidate
            self.deadline = nil
            self.candidate = nil
            if suppressing?.released(in: sample) == true { reset() }
            return candidate
        }
        if latched != nil, let chord = suppressing {
            guard chord.released(in: sample) else { return nil }
            reset()
            return nil
        }
        let stopHeld = stop.held(in: sample)
        let statsHeld = stats.held(in: sample)
        let next: ControllerShortcutAction? = stopHeld == statsHeld ? nil : (stopHeld ? .stop : .stats)
        if next != candidate {
            candidate = next
            deadline = next.map { _ in now + Self.holdSeconds }
        }
        return nil
    }
}
