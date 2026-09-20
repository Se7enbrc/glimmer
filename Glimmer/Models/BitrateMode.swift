//
//  BitrateMode.swift
//
//  How much to ask for: the most the link can carry (the default), or the
//  lighter ask Glimmer used before. The route and radio gates apply to both;
//  the mode only sets the boost. Read at session start, like the display mode.
//

import Foundation

public enum BitrateMode: String, CaseIterable, Identifiable, Sendable {
    case highestQuality
    case bandwidthSaver

    public var id: String { rawValue }

    public static let defaultMode: BitrateMode = .highestQuality

    /// UserDefaults key. Registered (never written) with `defaultMode` in
    /// GlimmerApp so the raw read agrees with the declared default.
    public static let defaultsKey = "bitrateMode"

    public var displayName: String {
        switch self {
        case .highestQuality: return "Highest quality"
        case .bandwidthSaver: return "Bandwidth saver"
        }
    }

    /// Absent or unrecognised lands on the default rather than guessing.
    public static func persisted(rawValue: String?) -> BitrateMode {
        rawValue.flatMap(BitrateMode.init(rawValue:)) ?? defaultMode
    }
}
