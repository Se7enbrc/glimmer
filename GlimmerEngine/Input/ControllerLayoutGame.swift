// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

public struct ControllerLayoutGameRecord: Identifiable, Hashable, Codable, Sendable {
    public let pcID: String
    public let appID: UInt32
    public let pcName: String
    public let name: String
    public var id: ControllerLayoutScope { .game(pcID: pcID, appID: appID) }

    public init(pcID: String, appID: UInt32, pcName: String, name: String) {
        self.pcID = pcID
        self.appID = appID
        self.pcName = pcName
        self.name = name
    }
}
