// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

package struct SystemStatsSnapshot: Sendable, Equatable {

    package init(
        batteryPercent: Int? = nil,
        batteryCharging: Bool? = nil,
        cpuPercent: Double? = nil,
        ramPercent: Double? = nil
    ) {
        self.batteryPercent = batteryPercent
        self.batteryCharging = batteryCharging
        self.cpuPercent = cpuPercent
        self.ramPercent = ramPercent
    }

    /// Battery percentage (0-100). nil on desktops with no battery.
    package var batteryPercent: Int?
    /// True if AC is plugged in. Drives the "charging" vs "discharging"
    /// glyph in the overlay row.
    package var batteryCharging: Bool?
    /// CPU usage 0-100, sum across all cores normalized to 100% =
    /// "all cores fully busy". Activity Monitor's "User + System" line.
    package var cpuPercent: Double?
    /// RAM usage 0-100. (active + wired + compressed) / total - matches
    /// Activity Monitor's "Memory Used" percentage.
    package var ramPercent: Double?
}
