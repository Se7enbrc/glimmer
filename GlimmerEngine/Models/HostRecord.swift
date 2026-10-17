// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

/// A paired Sunshine/GeForce Experience host known to Glimmer. Mirrors the
/// shape of the moonlight-qt-persisted host blob so the one-shot migration
/// in `HostsStore.migrateFromMoonlightQtIfNeeded` can copy values verbatim.
package struct HostRecord: Identifiable, Hashable, Sendable {
    package let id: String  // uuid from Moonlight, or hostname fallback
    package let name: String
    package let customName: String?
    package let localAddress: String?
    package let manualAddress: String?
    package let apps: [LibraryApp]
    package let lastConnected: Date?
    package let serverCertPEM: String?    // pinned from moonlight-qt's hosts.N.srvcert (migration)
    package let appVersion: String?

    /// The PC's MAC from /serverinfo's `<mac>`, for Wake on LAN.
    package let macAddress: String?

    /// Per-PC "Wake on LAN": on by default; only matters when a MAC is known.
    package var wakeOnLAN: Bool = true

    package init(
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
        wakeOnLAN: Bool = true
    ) {
        self.id = id
        self.name = name
        self.customName = customName
        self.localAddress = localAddress
        self.manualAddress = manualAddress
        self.apps = apps
        self.lastConnected = lastConnected
        self.serverCertPEM = serverCertPEM
        self.appVersion = appVersion
        self.macAddress = macAddress
        self.wakeOnLAN = wakeOnLAN
    }

    package var displayName: String { customName ?? name }

    /// The app a spoken or typed name means: an exact match first, then one
    /// that differs only in case, accents or surrounding spaces.
    package func app(named name: String) -> LibraryApp? {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return apps.first { $0.name == wanted }
            ?? apps.first {
                $0.name.compare(wanted, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }
    }
}
