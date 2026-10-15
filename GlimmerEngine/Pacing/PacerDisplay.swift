// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import QuartzCore

/// Display capabilities are read on main at bind, screen change and the existing rate-hint check.
public struct PacerScreen: Sendable {
    public let identity: String
    public let maximumHz: Double
    public let minimumHz: Double?
    public let scale: Double

    public init(identity: String, maximumHz: Double, minimumHz: Double?, scale: Double) {
        self.identity = identity
        self.maximumHz = maximumHz
        self.minimumHz = minimumHz
        self.scale = scale
    }
}

/// The shell creates a display-bound link; its target and steady tick remain owned by the engine.
/// Capture the view weakly. A nil factory result means the display has detached.
@MainActor
public struct PacerDisplay {
    let makeLink: @MainActor (NSObject, Selector) -> CADisplayLink?
    let screen: @MainActor () -> PacerScreen
    let tickOffMain: @MainActor () -> Bool
    let prepareTickThread: @Sendable () -> Void

    public init(makeLink: @escaping @MainActor (NSObject, Selector) -> CADisplayLink?,
                screen: @escaping @MainActor () -> PacerScreen, tickOffMain: @escaping @MainActor () -> Bool,
                prepareTickThread: @escaping @Sendable () -> Void) {
        self.makeLink = makeLink
        self.screen = screen
        self.tickOffMain = tickOffMain
        self.prepareTickThread = prepareTickThread
    }
}
