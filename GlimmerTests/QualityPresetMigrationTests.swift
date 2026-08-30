//
//  QualityPresetMigrationTests.swift
//
//  Covers QualityPreset.migrated(fromPersistedRawValue:) - the remap that
//  rescues the two presets the rework deleted. The bug it guards against:
//  "smooth" and "maximum" no longer decode, so the load fell back to the
//  DEFAULT (Native Retina, panel-native + top of the bitrate curve) and the
//  next persist rewrote the key - a user who chose Smooth for a thin Wi-Fi
//  link was moved to the most demanding preset in the app, permanently.
//

import Testing
@testable import Glimmer

struct QualityPresetMigrationTests {

    // MARK: Legacy raw values

    @Test func smoothBecomesHiDPI() {
        // Smooth was "stay fluid, spend fewer bits". HiDPI is that preset now:
        // a quarter of the pixels, so a quarter of the bitrate.
        #expect(QualityPreset.migrated(fromPersistedRawValue: "smooth") == .hidpi)
    }

    @Test func maximumBecomesNativeRetina() {
        // Maximum was "sharpest picture, spend the bandwidth" - Native Retina.
        #expect(QualityPreset.migrated(fromPersistedRawValue: "maximum") == .matchDisplay)
    }

    // MARK: Current raw values pass through

    @Test func liveRawValuesDecodeToThemselves() {
        for preset in QualityPreset.allCases {
            #expect(QualityPreset.migrated(fromPersistedRawValue: preset.rawValue) == preset)
        }
    }

    // MARK: Unknown input

    @Test func unrecognisedRawValueLandsOnTheDefault() {
        // A downgrade from a build carrying a preset this one has never heard
        // of, or a hand-edited plist. Guessing would be worse than the default.
        #expect(QualityPreset.migrated(fromPersistedRawValue: "ultra") == QualityPreset.defaultPreset)
        #expect(QualityPreset.migrated(fromPersistedRawValue: "") == QualityPreset.defaultPreset)
        #expect(QualityPreset.defaultPreset == .matchDisplay)
    }

    // MARK: Idempotence

    @Test func migratingTwiceChangesNothing() {
        // The one-shot rewrite in AppModel keys off `raw != preset.rawValue`, so
        // a second pass over an already-migrated value must be a fixed point -
        // otherwise the key would be rewritten on every launch.
        for raw in ["smooth", "maximum", "matchDisplay", "hidpi", "custom", "nonsense"] {
            let once = QualityPreset.migrated(fromPersistedRawValue: raw)
            let twice = QualityPreset.migrated(fromPersistedRawValue: once.rawValue)
            #expect(once == twice)
        }
    }
}
