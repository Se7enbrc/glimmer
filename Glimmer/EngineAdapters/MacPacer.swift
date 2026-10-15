// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AppKit
import GlimmerEngine
import QuartzCore

/// AppKit attachment and preferences stay in the shell; ticks call the engine's target directly.
enum MacPacer {
    static let tickOffMainDefaultsKey = "pacerTickOffMain"
    static let realtimeDefaultsKey = "pacerTickRealtime"

    @MainActor
    static func display(for view: NSView) -> PacerDisplay {
        PacerDisplay(makeLink: { [weak view] target, selector in
            view?.displayLink(target: target, selector: selector)
        }, screen: { [weak view] in
            guard let view else { return PacerScreen(identity: "none", maximumHz: 0, minimumHz: nil, scale: 1) }
            let screen = view.window?.screen
            return PacerScreen(identity: screen?.cgDirectDisplayID.map { String($0) } ?? "none",
                               maximumHz: panelMaxHz(for: view), minimumHz: variableMinimumHz(for: view),
                               scale: Double(screen?.backingScaleFactor ?? 1))
        }, tickOffMain: { UserDefaults.standard.bool(forKey: tickOffMainDefaultsKey) },
           prepareTickThread: prepareTickThread)
    }

    @MainActor
    static func panelMaxHz(for view: NSView) -> Double {
        let screen = view.window?.screen ?? NSScreen.main
        return FramePacer.panelMaxHz(minimumInterval: screen?.minimumRefreshInterval ?? 0,
                          maximumFramesPerSecond: screen?.maximumFramesPerSecond ?? 0)
    }
    @MainActor
    static func variableMinimumHz(for view: NSView) -> Double? {
        guard let screen = view.window?.screen ?? NSScreen.main else { return nil }
        return FramePacer.variableMinimumHz(minimumInterval: screen.minimumRefreshInterval,
                                 maximumInterval: screen.maximumRefreshInterval,
                                 granularity: screen.displayUpdateGranularity)
    }
}
