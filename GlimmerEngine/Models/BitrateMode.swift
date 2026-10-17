// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  BitrateMode.swift
//
//  How much to ask for: the most the link can carry (the default), or the
//  lighter ask Glimmer used before. The route and radio gates apply to both;
//  the mode only sets the boost. Read at session start, like the display mode.
//

import Foundation

package enum BitrateMode: String, CaseIterable, Identifiable, Sendable {
    case highestQuality
    case bandwidthSaver

    package var id: String { rawValue }

    package static let defaultMode: BitrateMode = .highestQuality

    /// UserDefaults key. Registered (never written) with `defaultMode` in
    /// GlimmerApp so the raw read agrees with the declared default.
    package static let defaultsKey = "bitrateMode"

    package var displayName: String {
        switch self {
        case .highestQuality: return "Highest quality"
        case .bandwidthSaver: return "Bandwidth saver"
        }
    }

    /// Absent or unrecognised lands on the default rather than guessing.
    package static func persisted(rawValue: String?) -> BitrateMode {
        rawValue.flatMap(BitrateMode.init(rawValue:)) ?? defaultMode
    }
}
