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

    /// Absent or unrecognised lands on the default rather than guessing.
    package static func persisted(rawValue: String?) -> BitrateMode {
        rawValue.flatMap(BitrateMode.init(rawValue:)) ?? defaultMode
    }
}

/// The one Bandwidth control people see: the start rate and whether it adapts,
/// stored as the two settings sessions already read. iOS offers Automatic and Saver.
public enum BandwidthChoice: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case maximum
    case saver

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .automatic: return "Automatic"
        case .maximum: return "Maximum"
        case .saver: return "Saver"
        }
    }

    /// Saver wins over adaptive so a saved saver choice never reads as Automatic.
    package init(bitrateMode: BitrateMode, adaptive: Bool) {
        switch (bitrateMode, adaptive) {
        case (.bandwidthSaver, _): self = .saver
        case (.highestQuality, true): self = .automatic
        case (.highestQuality, false): self = .maximum
        }
    }

    package var bitrateMode: BitrateMode { self == .saver ? .bandwidthSaver : .highestQuality }
    public var adaptive: Bool { self == .automatic }
}
