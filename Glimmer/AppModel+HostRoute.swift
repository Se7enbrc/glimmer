//
//  AppModel+HostRoute.swift
//
//  The route class toward the selected PC (the readiness chip's bolt or Wi-Fi glyph): one silent,
//  connected UDP NWConnection whose path updates on every route change. Not the telemetry-only
//  StreamRouteProbe; a Wi-Fi route adds a 1 Hz PHY-rate read off the main thread.
//

import Foundation
import Network
import SwiftUI
import Observation

/// Live wired/Wi-Fi classification of the kernel route toward one host.
/// Owned by `AppModel` (see `hostRoute`), re-pointed via `refreshHostRoute()`
/// whenever the selected host's address changes.
@MainActor
@Observable
final class HostRouteMonitor {

    /// The route class the kernel chose toward the monitored host. `tunnel`
    /// (utun/ipsec - Network.framework's `.other`) and `unknown` (no route /
    /// not yet resolved) both render as NO glyph: absent knowledge stays
    /// unlabelled, never guessed.
    enum RouteClass {
        case wired, wifi, tunnel, unknown
    }

    private(set) var routeClass: RouteClass = .unknown

    /// Median of the last ten 1 Hz PHY-rate reads while the route is Wi-Fi;
    /// nil otherwise. A single read can catch a rate-adaptation dip (206 Mbps
    /// seen on a link that sits at 1100), so the ask is gated on the median.
    private(set) var wifiPhyRateMbps: Double?
    @ObservationIgnored private var phySamples: [Double] = []
    @ObservationIgnored private var phyTimer: DispatchSourceTimer?
    @ObservationIgnored private let radio = WiFiTelemetry()

    /// Runs while the route is Wi-Fi, streaming or not, so a reconnect always
    /// has a median. The CoreWLAN read happens on the monitor's utility queue;
    /// the main actor only files the result.
    private func setPhySampling(_ on: Bool) {
        phyTimer?.cancel()
        phyTimer = nil
        phySamples.removeAll()
        wifiPhyRateMbps = nil
        guard on else { return }
        let radio = radio
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .seconds(1), leeway: .milliseconds(100))
        timer.setEventHandler { @Sendable [weak self] in
            guard let self, let rate = radio.txRateMbps() else { return }
            Task { @MainActor in self.recordPhyRate(rate) }
        }
        timer.resume()
        phyTimer = timer
    }

    /// Assigns only a moved median: every write re-renders the spec chips.
    private func recordPhyRate(_ rate: Double) {
        guard phyTimer != nil else { return }  // a read that landed after sampling stopped
        phySamples.append(rate)
        if phySamples.count > 10 { phySamples.removeFirst() }
        let median = phySamples.sorted()[phySamples.count / 2]
        if median != wifiPhyRateMbps { wifiPhyRateMbps = median }
    }

    /// Called when the route leaves wired; AppModel parks AWDL if a stream is up.
    @ObservationIgnored var onLeftWired: (() -> Void)?

    /// Chip glyph for the current route - bolt for wired, arcs for Wi-Fi,
    /// nothing when the route is a tunnel or unknown.
    var glyphSystemName: String? {
        switch routeClass {
        case .wired: return "bolt.fill"
        case .wifi: return "wifi"
        case .tunnel, .unknown: return nil
        }
    }

    /// VoiceOver flavour appended to the chip sentence ("..., over Wi-Fi").
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
        setPhySampling(false)
        guard let address, !address.isEmpty else { return }

        // The port is irrelevant to route selection (only the destination
        // address picks the egress interface) - discard keeps intent obvious.
        let conn = NWConnection(host: NWEndpoint.Host(address), port: 9, using: .udp)
        let gen = generation
        conn.pathUpdateHandler = { [weak self] path in
            // Classify on the monitor queue (cheap enum derivation), publish
            // on the main actor where SwiftUI observes `routeClass`.
            let fresh = Self.classify(path)
            Task { @MainActor [weak self] in
                guard let self, self.generation == gen else { return }
                if (fresh == .wifi) != (self.routeClass == .wifi) { self.setPhySampling(fresh == .wifi) }
                if self.routeClass == .wired, fresh != .wired { self.onLeftWired?() }
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

extension AppModel {

    /// The address `refreshHostRoute()` monitors: the one a stream dials. Keyed by
    /// address, not id, because a heal or re-pair after a DHCP move rewrites it under
    /// the same uuid and the glyph must follow.
    var selectedHostRouteAddress: String? {
        selectedHost.map(Self.routeAddress)
    }

    /// The address `nativeServerInfo(for:)` dials: discovered, then typed, then the name.
    nonisolated static func routeAddress(_ host: Host) -> String {
        host.localAddress ?? host.manualAddress ?? host.name
    }

    /// Re-point the route monitor at the selected PC; a nil selection tears the
    /// parked socket down. `selectionChanged(from:)` calls this on every address
    /// change, so it runs with the launcher closed too.
    func refreshHostRoute() {
        hostRoute.monitor(address: selectedHostRouteAddress)
    }

    /// A stream parks AWDL at start only off a wired route; one that leaves
    /// wired mid-stream parks it now (`suppressForStream` is idempotent).
    func parkAWDLIfStreaming() {
        if isStreaming { AWDLHelperManager.shared.suppressForStream() }
    }
}
