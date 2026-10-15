// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  Host.swift
//
//  Persisted-host and live-status model types shared across the UI and
//  manager.
//

import GlimmerEngine
import Foundation
import SwiftUI

// MARK: - Persisted host model

// Keep the launcher preference in the Mac shell while the PC record travels with the engine.
struct Host: Identifiable, Hashable {
    var record: HostRecord
    var launcherStyle: LauncherStyle = .buttons

    var id: String { record.id }
    var name: String { record.name }
    var customName: String? { record.customName }
    var localAddress: String? { record.localAddress }
    var manualAddress: String? { record.manualAddress }
    var apps: [LibraryApp] { record.apps }
    var lastConnected: Date? { record.lastConnected }
    var serverCertPEM: String? { record.serverCertPEM }
    var appVersion: String? { record.appVersion }
    var macAddress: String? { record.macAddress }
    var displayName: String { record.displayName }
    var wakeOnLAN: Bool {
        get { record.wakeOnLAN }
        set { record.wakeOnLAN = newValue }
    }

    init(
        id: String,
        name: String,
        customName: String?,
        localAddress: String?,
        manualAddress: String?,
        apps: [LibraryApp],
        lastConnected: Date?,
        serverCertPEM: String?,
        appVersion: String?,
        macAddress: String?,
        wakeOnLAN: Bool = true,
        launcherStyle: LauncherStyle = .buttons
    ) {
        record = HostRecord(
            id: id, name: name, customName: customName, localAddress: localAddress, manualAddress: manualAddress,
            apps: apps, lastConnected: lastConnected, serverCertPEM: serverCertPEM, appVersion: appVersion,
            macAddress: macAddress, wakeOnLAN: wakeOnLAN)
        self.launcherStyle = launcherStyle
    }

    func app(named name: String) -> LibraryApp? { record.app(named: name) }
}

// MARK: - Deterministic hashing
//
// Swift's `String.hashValue` is intentionally randomized per process (it's
// seeded from a per-launch nonce as a defence against hash-flooding attacks
// on dictionaries). Anything we use for stable visual identity - per-host
// tint colour, monogram chip background, anywhere we'd want "Tower" to read
// as the same blue every time the user opens the app - has to use a
// deterministic hash instead.
//
// FNV-1a-64 chosen because:
//   * Short to implement (~10 lines, no SipHash table or external dep).
//   * Determinism is the only requirement - we don't need cryptographic
//     hashing or even strong avalanche; we just need "same input → same
//     output across launches".
//   * 64-bit output is wider than we need (we mod by colors.count, ~12),
//     but the extra width is free and avoids per-process collisions
//     between similarly-named hosts ("Tower" vs "Tower 2").
extension String {
    /// FNV-1a 64-bit hash of this string's UTF-8 bytes. Deterministic
    /// across process launches - unlike `hashValue`, which Swift seeds
    /// from a per-process nonce.
    func deterministicHash() -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325  // FNV offset basis
        for b in self.utf8 {
            h ^= UInt64(b)
            h &*= 0x0000_0100_0000_01b3        // FNV prime
        }
        return h
    }
}

extension LibraryApp {
    /// Steam has no SF Symbol, so it gets its own mark, built as a custom symbol so it
    /// sizes and tints like the others.
    var icon: Image {
        switch name.lowercased() {
        case _ where isDesktop: Image(systemName: "macwindow")
        case let lowered where lowered.contains("steam"): Image("steam")
        case let lowered where lowered.contains("big picture"): Image(systemName: "tv")
        default: Image(systemName: "app")
        }
    }
}

extension QualityPreset {
    var subtitle: String {
        switch self {
        case .matchDisplay: return "Every pixel of this Mac's display. Needs a solid network."
        case .hidpi: return "This Mac's usual Retina scale. A touch softer, far less bandwidth."
        case .custom: return "Pick your own resolution and refresh rate."
        }
    }
}
