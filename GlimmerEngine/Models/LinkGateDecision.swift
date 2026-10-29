// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

package struct LinkGateDecision: Sendable {

    package init(
        interfaceName: String? = nil,
        mtu: Int? = nil,
        isTunnel: Bool,
        rtt: RttStats? = nil,
        rttPreLaunch: Bool = false,
        configuredBitrateKbps: Int,
        askedBitrateKbps: Int,
        packetSize: Int
    ) {
        self.interfaceName = interfaceName
        self.mtu = mtu
        self.isTunnel = isTunnel
        self.rtt = rtt
        self.rttPreLaunch = rttPreLaunch
        self.configuredBitrateKbps = configuredBitrateKbps
        self.askedBitrateKbps = askedBitrateKbps
        self.packetSize = packetSize
    }

    package var interfaceName: String?
    package var mtu: Int?
    package var isTunnel: Bool
    package var rtt: RttStats?
    /// Whether `rtt` is the pre-launch window (true) or every sample (false).
    package var rttPreLaunch: Bool = false
    package var configuredBitrateKbps: Int
    package var askedBitrateKbps: Int
    package var packetSize: Int
}
