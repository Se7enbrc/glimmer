// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AppKit
import GlimmerEngine

extension VideoDecoder {
    convenience init(macColorSpace: ColorSpace, colorRange: ColorRange) {
        self.init(colorSpace: macColorSpace, colorRange: colorRange)
        displayInfo = { [weak self] in
            let view = self?.displayLayer?.delegate as? NSView
            guard let screen = view?.window?.screen ?? NSScreen.main else { return nil }
            return VideoDisplayInfo(
                currentHeadroom: Double(screen.maximumExtendedDynamicRangeColorComponentValue),
                potentialHeadroom: Double(screen.maximumPotentialExtendedDynamicRangeColorComponentValue),
                name: screen.localizedName, maximumFramesPerSecond: screen.maximumFramesPerSecond)
        }
    }

    public func startPacing(drivingView view: NSView, configuredFps: Int32, warmHandover: Bool = false) {
        startPacing(display: MacPacer.display(for: view), configuredFps: configuredFps, warmHandover: warmHandover)
    }
}
