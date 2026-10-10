// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  ModelTypesTests.swift
//
//  The small model types behind the UI: PC and app matching, chord labels,
//  the stable hash, bitrate and codec choices, and Settings panes. Copy is
//  checked against AGENTS.md (no em dashes, no exclamation marks, no "host").
//

import Foundation
import Testing
@testable import Glimmer

struct ModelTypesTests {

    private func app(_ id: Int, _ name: String) -> LibraryApp {
        LibraryApp(id: id, name: name, hdr: false, hidden: false)
    }

    private func pc(apps: [LibraryApp]) -> Glimmer.Host {
        Host(id: "u", name: "Tower", customName: nil, localAddress: nil, manualAddress: nil,
             apps: apps, lastConnected: nil, serverCertPEM: nil, appVersion: nil, macAddress: nil)
    }

    @Test func aCustomNameWinsOverThePCsOwn() {
        let named = Host(id: "u", name: "TOWER", customName: "Den", localAddress: nil, manualAddress: nil,
                         apps: [], lastConnected: nil, serverCertPEM: nil, appVersion: nil, macAddress: nil)
        #expect(named.displayName == "Den")
        #expect(pc(apps: []).displayName == "Tower")
        #expect(pc(apps: []).wakeOnLAN)
    }

    @Test func aSpokenAppNameMatchesExactlyBeforeLoosely() {
        let host = pc(apps: [app(1, "steam"), app(2, "Steam"), app(3, "Café Racer"), app(4, "Desktop")])
        #expect(host.app(named: "Steam")?.id == 2)
        #expect(host.app(named: "STEAM")?.id == 1)
        #expect(host.app(named: "  desktop \n")?.id == 4)
        #expect(host.app(named: "cafe racer")?.id == 3)
        #expect(host.app(named: "Cafe") == nil)
    }

    @Test func appIconsFollowTheName() {
        #expect(app(1, "Desktop").systemImage == "macwindow")
        #expect(app(2, "Steam Big Picture").systemImage == "gamecontroller.fill")
        #expect(app(3, "Big Picture").systemImage == "tv")
        #expect(app(4, "Helldivers 2").systemImage == "app")
    }

    @Test func chordsReadAndSerializeInModifierOrder() {
        let all = HotkeyChord(ctrl: true, alt: true, shift: true, cmd: true, keyChar: "q")
        #expect(all.displayString == "⌃⌥⇧⌘Q")
        #expect(all.serialized == "ctrl+alt+shift+cmd+q")
        #expect(HotkeyChord.defaultQuit.displayString == "⌃Q")
        #expect(HotkeyChord.defaultStats.serialized == "ctrl+i")
        let bare = HotkeyChord(ctrl: false, alt: false, shift: false, cmd: false, keyChar: "Z")
        #expect(bare.displayString == "Z")
        #expect(bare.serialized == "z")
    }

    @Test func everyDefaultChordIsControlPlusAUniqueLetter() {
        let defaults = [HotkeyChord.defaultQuit, .defaultStats, .defaultBookmark, .defaultReleasePointer, .defaultMiniPlayer]
        #expect(defaults.allSatisfy { $0.ctrl && !$0.alt && !$0.shift && !$0.cmd })
        #expect(Set(defaults.map(\.keyChar)).count == defaults.count)
    }

    @Test func aStoredChordDecodesFromItsJSONShape() throws {
        let json = #"{"ctrl":true,"alt":false,"shift":true,"cmd":false,"keyChar":"k"}"#
        let chord = try JSONDecoder().decode(HotkeyChord.self, from: Data(json.utf8))
        #expect(chord == HotkeyChord(ctrl: true, alt: false, shift: true, cmd: false, keyChar: "k"))
    }

    @Test func aButtonChordListsInDeclarationOrder() {
        #expect(ControllerButton.describe([.r1, .faceDown, .l1]) == "✕ + L1 + R1")
        #expect(ControllerButton.describe([]) == "Not set")
        #expect(Set(ControllerButton.allCases.map(\.label)).count == ControllerButton.allCases.count)
    }

    @Test func aRemovedQuitChordFallsBackInsteadOfDecoding() {
        #expect(ControllerQuitChord(rawValue: "home") == nil)
        #expect(ControllerQuitChord.none.displayName == "None (keyboard only)")
        #expect(ControllerQuitChord.l3r3.displayName == "L3 + R3 (stick clicks)")
        #expect(Set(ControllerQuitChord.allCases.map(\.displayName)).count == ControllerQuitChord.allCases.count)
    }

    @Test func theHashIsFNV1aAndSurvivesRelaunch() {
        #expect("".deterministicHash() == 0xcbf2_9ce4_8422_2325)
        #expect("a".deterministicHash() == 0xaf63_dc4c_8601_ec8c)
        #expect("foobar".deterministicHash() == 0x8594_4171_f739_67e8)
        #expect("Tower".deterministicHash() != "Tower 2".deterministicHash())
    }

    @Test func bitrateModeFallsBackToHighestQuality() {
        #expect(BitrateMode.defaultMode == .highestQuality)
        #expect(BitrateMode.persisted(rawValue: nil) == .highestQuality)
        #expect(BitrateMode.persisted(rawValue: "bandwidthSaver") == .bandwidthSaver)
        #expect(BitrateMode.persisted(rawValue: "turbo") == .highestQuality)
        #expect(BitrateMode.highestQuality.displayName == "Highest quality")
        #expect(BitrateMode.bandwidthSaver.displayName == "Bandwidth saver")
        #expect(BitrateMode.defaultsKey == "bitrateMode")
        #expect(BitrateMode.bandwidthSaver.id == "bandwidthSaver")
    }

    @Test func aCodecCapRemovesCeilingsAndKeepsFallbacks() {
        let probed: VideoFormats = [.h264, .hevc, .hevcMain10, .av1, .av1Main10]
        #expect(HostCodecPreference.auto.apply(to: probed) == probed)
        #expect(HostCodecPreference.hevc.apply(to: probed) == [.h264, .hevc, .hevcMain10])
        #expect(HostCodecPreference.h264.apply(to: probed) == [.h264])
        // A Mac that cannot decode AV1 is not changed by capping it.
        #expect(HostCodecPreference.hevc.apply(to: [.h264, .hevc]) == [.h264, .hevc])
        #expect(HostCodecPreference.allCases.map(\.id) == ["auto", "hevc", "h264"])
    }

    @Test func qualityPresetsAreNamedByOutcome() {
        #expect(QualityPreset.allCases == [.matchDisplay, .hidpi, .custom])
        #expect(QualityPreset.allCases.map(\.displayName) == ["Sharpest", "Balanced", "Custom"])
        #expect(QualityPreset.defaultPreset == .matchDisplay)
        #expect(QualityPreset.custom.subtitle == "Pick your own resolution and refresh rate.")
    }

    @Test func settingsPanesKeepTheirStableRawValues() {
        #expect(SettingsPane.allCases.map(\.title) == ["General", "Quality", "PCs", "Input", "Diagnostics", "About"])
        #expect(SettingsPane.streaming.rawValue == "streaming")
        #expect(SettingsPane.shortcuts.rawValue == "shortcuts")
        #expect(Set(SettingsPane.allCases.map(\.systemImage)).count == SettingsPane.allCases.count)
        #expect(SettingsPane.about.systemImage == "info.circle.fill")
    }

    @Test func userFacingNamesFollowTheCopyRules() {
        let copy: [String] = BitrateMode.allCases.map(\.displayName)
            + HostCodecPreference.allCases.map(\.displayName)
            + QualityPreset.allCases.flatMap { [$0.displayName, $0.subtitle] }
            + SettingsPane.allCases.map(\.title)
            + ControllerQuitChord.allCases.map(\.displayName)
            + [StreamDisplayMode.fullScreen.displayName, StreamDisplayMode.window.displayName]
        for line in copy {
            #expect(!line.contains("—") && !line.contains("!"), "\(line)")
            #expect(!line.lowercased().contains("host") && !line.lowercased().contains("server"), "\(line)")
        }
    }
}
