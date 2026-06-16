//
//  MoonlightManager+HostRoute.swift
//
//  Always-on route classification for the SELECTED host — feeds the quiet
//  bolt / Wi-Fi glyph on the launcher's readiness chip ("Ready · 12 ms ⚡").
//
//  DELIBERATELY not the engine's `StreamRouteProbe`: that probe is
//  constructed by the opt-in telemetry exporter (gate-on only) and must stay
//  removable with it — nothing UI-facing may depend on it. This monitor rides
//  pure Network.framework instead: one connected UDP NWConnection to the host
//  (connecting a UDP socket sends NOTHING — it only asks the kernel to bind a
//  route), whose NWPath reports the egress interface class for THAT
//  destination. Path updates are pushed on every route-table event
//  (dock/undock, VPN up, Wi-Fi join), so the glyph flips live with no timers.
//  Idle cost: one parked socket, zero traffic. Unlike the exporter probe we
//  tolerate hostnames here — Network.framework resolves asynchronously off
//  the main thread, and the launcher has no hot path to protect.
//

import Foundation
import Network
import SwiftUI
import Observation

/// Live wired/Wi-Fi classification of the kernel route toward one host.
/// Owned by `MoonlightManager` (see `hostRoute`), re-pointed by the launcher
/// via `refreshHostRoute()` whenever the selected host changes.
@MainActor
@Observable
final class HostRouteMonitor {

    /// The route class the kernel chose toward the monitored host. `tunnel`
    /// (utun/ipsec — Network.framework's `.other`) and `unknown` (no route /
    /// not yet resolved) both render as NO glyph: absent knowledge stays
    /// unlabelled, never guessed.
    enum RouteClass {
        case wired, wifi, tunnel, unknown
    }

    private(set) var routeClass: RouteClass = .unknown

    /// Chip glyph for the current route — bolt for wired, arcs for Wi-Fi,
    /// nothing when the route is a tunnel or unknown.
    var glyphSystemName: String? {
        switch routeClass {
        case .wired: return "bolt.fill"
        case .wifi: return "wifi"
        case .tunnel, .unknown: return nil
        }
    }

    /// VoiceOver flavour appended to the chip sentence ("…, over Wi-Fi").
    var accessibilityDescription: String? {
        switch routeClass {
        case .wired: return "over Ethernet"
        case .wifi: return "over Wi-Fi"
        case .tunnel, .unknown: return nil
        }
    }

    @ObservationIgnored private var connection: NWConnection?
    /// Bumped on every retarget; stale path callbacks (from a connection we
    /// already cancelled) compare against it and drop their result, so a
    /// quick host switch can't paint the old host's route onto the new chip.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let queue = DispatchQueue(
        label: "io.ugfugl.Glimmer.ui.hostRoute", qos: .utility)

    /// Point the monitor at a new destination (nil tears down to `.unknown`).
    /// Cancels any previous socket first; NWConnection releases its handlers
    /// on cancel, so the retained-handler cycle is broken deterministically.
    func monitor(address: String?) {
        connection?.cancel()
        connection = nil
        generation += 1
        routeClass = .unknown
        guard let address, !address.isEmpty else { return }

        // The port is irrelevant to route selection (only the destination
        // address picks the egress interface) — discard keeps intent obvious.
        let conn = NWConnection(host: NWEndpoint.Host(address), port: 9, using: .udp)
        let gen = generation
        conn.pathUpdateHandler = { [weak self] path in
            // Classify on the monitor queue (cheap enum derivation), publish
            // on the main actor where SwiftUI observes `routeClass`.
            let fresh = Self.classify(path)
            Task { @MainActor [weak self] in
                guard let self, self.generation == gen else { return }
                self.routeClass = fresh
            }
        }
        conn.start(queue: queue)
        connection = conn
    }

    /// NWPath → route class. Tunnel is checked FIRST: a host reached through
    /// utun rides `.other`, and the radio underneath is NOT what the kernel
    /// routed to (the same honesty rule the engine's exporter probe follows).
    private nonisolated static func classify(_ path: NWPath) -> RouteClass {
        guard path.status == .satisfied else { return .unknown }
        if path.usesInterfaceType(.other) { return .tunnel }
        if path.usesInterfaceType(.wiredEthernet) { return .wired }
        if path.usesInterfaceType(.wifi) { return .wifi }
        return .unknown
    }
}

extension MoonlightManager {

    /// The destination `refreshHostRoute()` monitors for the current
    /// selection — the same fallback chain `nativeServerInfo(for:)` dials, so
    /// the glyph always classifies the address a stream would actually use.
    /// Exposed so the launcher can key its refresh task on the ADDRESS rather
    /// than `selectedHost?.id`: re-pairing a host after a DHCP move rewrites
    /// localaddress/manualaddress under the SAME uuid, so an id-keyed task
    /// never re-fires and the glyph keeps classifying the route to the dead
    /// IP until a host switch or relaunch.
    var selectedHostRouteAddress: String? {
        selectedHost.map { $0.localAddress ?? $0.manualAddress ?? $0.name }
    }

    /// Re-point the readiness chip's route monitor at the currently selected
    /// host (nil selection tears the parked socket down — see the launcher's
    /// empty-hosts task in MainWindow, which relies on that to release the
    /// socket when the last PC is unpaired). Driven by the launcher
    /// (`.task(id: selectedHostRouteAddress)`) so it follows host switches
    /// AND same-host address changes without the manager needing its own
    /// observer.
    func refreshHostRoute() {
        hostRoute.monitor(address: selectedHostRouteAddress)
    }
}
