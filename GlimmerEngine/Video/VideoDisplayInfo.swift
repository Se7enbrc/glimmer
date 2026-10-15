// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

/// Display observations supplied by the shell on main; nil means no attached display.
public struct VideoDisplayInfo: Sendable {
    public let currentHeadroom: Double
    public let potentialHeadroom: Double
    public let name: String
    public let maximumFramesPerSecond: Int

    public init(currentHeadroom: Double, potentialHeadroom: Double, name: String, maximumFramesPerSecond: Int) {
        self.currentHeadroom = currentHeadroom
        self.potentialHeadroom = potentialHeadroom
        self.name = name
        self.maximumFramesPerSecond = maximumFramesPerSecond
    }
}

extension VideoDecoder {
    /// Use the same configuration as StreamConnection so source colour requests agree.
    public convenience init(configuration: StreamConnection.Configuration,
                            displayInfo: @escaping @MainActor () -> VideoDisplayInfo?) {
        self.init(colorSpace: configuration.request.colorSpace, colorRange: configuration.request.colorRange)
        self.displayInfo = displayInfo
    }
}
