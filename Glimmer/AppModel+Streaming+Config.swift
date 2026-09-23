//
//  AppModel+Streaming+Config.swift
//
//  The derived, read-only half of AppModel+Streaming.swift: the spec-surface
//  accessors (chips, summary, codec-aware bitrate), the state-aware hero verb,
//  and the Host → engine bridge (`nativeStreamConfig` / `nativeServerInfo` and
//  the authoritative TLS-pin resolution behind it). Split out of
//  AppModel+Streaming.swift to keep each file under the length limit; the
//  session lifecycle - stream(), its teardown, engine events, connect cancel -
//  stays there and in AppModel+Streaming+Events.swift.
//

import Foundation
import os.log

extension AppModel {

    // MARK: - Spec UI accessors

    // Codec (AV1/HEVC/H.264) is deliberately omitted from every user-facing
    // surface: it's an implementation detail the user never chose, and the codec
    // actually negotiated can differ from what's requested (Intel Macs drop AV1
    // → HEVC), so showing it risks displaying a value that's simply wrong. Users
    // care that it looks good, not which encoder produced it.
    var streamSpecSummary: String {
        let mbps = displayBitrateKbps / 1000
        let hdrTag = effectiveHDR ? " · HDR" : ""
        return "\(effectiveWidth) × \(effectiveHeight) · \(effectiveFPS) Hz\(hdrTag) · \(mbps) Mbps"
    }

    var streamSpecChips: [String] {
        let mbps = displayBitrateKbps / 1000
        var chips = [Self.resolutionLabel(width: effectiveWidth, height: effectiveHeight),
                     "\(effectiveFPS) Hz"]
        if effectiveHDR { chips.append("HDR") }
        chips.append("\(mbps) Mbps")
        return chips
    }

    /// Codec-aware bitrate the spec surfaces show: what the engine actually sends
    /// for the selected host (AV1/HEVC spend ~20% fewer bits), so the chip/summary
    /// match the wire. Falls back to the H.264 dial when no host is selected.
    var displayBitrateKbps: Int {
        _ = displayInfoRevision  // codec override writes UserDefaults; bump re-evaluates the chip
        guard let host = selectedHost else { return effectiveBitrateKbps }
        return wireBitrateKbps(forFormats: offeredVideoFormats(for: host))
    }

    /// What this Mac offers the PC: the probed formats under the PC's codec
    /// choice (right-click › Codec), less the 10-bit ones when HDR is off.
    func offeredVideoFormats(for host: Host) -> VideoFormats {
        Self.videoFormats(HostCodecPreference.load(for: host.id).apply(to: .probedSupported), hdr: streamHDR)
    }

    /// With no 10-bit format on offer the PC encodes SDR, and the launch
    /// request leaves out hdrMode (sent only when one is offered).
    nonisolated static func videoFormats(_ formats: VideoFormats, hdr: Bool) -> VideoFormats {
        hdr ? formats : formats.subtracting(VideoFormats(rawValue: StreamProtocol.VIDEO_FORMAT_MASK_10BIT))
    }

    /// The dial is sized for Wi-Fi. Wired end to end (the Mac's route says
    /// Ethernet, the connect-time RTT agrees) asks for twice as much under a
    /// higher cap; the per-frame budget is what grain tracks, not the average.
    nonisolated static let wiredBitrateMultiplier = 2.0
    nonisolated static let wiredBitrateCapKbps = 500_000

    /// Wi-Fi asks for half as much again under the formula's cap; tested on a
    /// 6 GHz link with no hitches. `defaults write io.ugfugl.Glimmer
    /// bitrateBoostWifi -float N` overrides it without a rebuild.
    nonisolated static let wifiBitrateMultiplier = 1.5
    nonisolated static var wifiBitrateBoost: Double {
        let value = UserDefaults.standard.double(forKey: "bitrateBoostWifi")
        return value > 0 ? value : wifiBitrateMultiplier
    }

    /// The H.264-anchored quality dial (`effectiveBitrateKbps`) scaled by the
    /// negotiated codec's efficiency, then by the route. The spec UI and
    /// `nativeStreamConfig` both read this so the shown bitrate can't drift
    /// from what's sent. Custom skips the codec discount, as before.
    func wireBitrateKbps(forFormats formats: VideoFormats) -> Int {
        StreamPathMTU.wifiAskKbps(ask: routeAskKbps(forFormats: formats), phyRateMbps: hostRoute.wifiPhyRateMbps)
    }

    /// The route's ask before the Wi-Fi radio gate: dial × codec × boost.
    /// Bandwidth saver is the lighter ask from before the boosts existed.
    func routeAskKbps(forFormats formats: VideoFormats) -> Int {
        let decision = bitrateDecision(forFormats: formats)
        let cap = decision.mode == .highestQuality ? Self.routeBoost(hostRoute.routeClass).capKbps : Self.maxBitrateKbps
        return Self.wireBitrateKbps(dial: decision.dialKbps, codecMultiplier: decision.codecMultiplier,
                                    boost: decision.boost, capKbps: cap)
    }

    /// The inputs `routeAskKbps` multiplies, also recorded in the telemetry config event.
    func bitrateDecision(forFormats formats: VideoFormats) -> BitrateDecision {
        var codec = Self.codecBudgetMultiplier(for: formats)
        if case .custom = qualityPreset { codec = 1 }
        let boost = bitrateMode == .highestQuality ? Self.routeBoost(hostRoute.routeClass).boost : 1
        return BitrateDecision(mode: bitrateMode, dialKbps: effectiveBitrateKbps, codecMultiplier: codec,
                               boost: boost, radioGatePhyMbps: hostRoute.wifiPhyRateMbps)
    }

    /// The part of the decision's boost the connect-time RTT may withdraw: only
    /// the wired one, since Wi-Fi has the radio gate instead.
    nonisolated static func rttWithdrawableBoost(_ decision: BitrateDecision,
                                                 route: HostRouteMonitor.RouteClass) -> Double {
        route == .wired ? decision.boost : 1
    }

    /// Boost and cap per route. A tunnel, or a route not resolved yet, keeps the
    /// unboosted ask: neither the radio gate nor the RTT withdrawal can trim it.
    nonisolated static func routeBoost(
        _ route: HostRouteMonitor.RouteClass, wifiBoost: Double = wifiBitrateBoost
    ) -> (boost: Double, capKbps: Int) {
        switch route {
        case .wired: (wiredBitrateMultiplier, wiredBitrateCapKbps)
        case .wifi: (wifiBoost, maxBitrateKbps)
        case .tunnel, .unknown: (1, maxBitrateKbps)
        }
    }

    /// Pure so the rule is testable: dial × codec × boost, clamped to the floor
    /// and the route's cap.
    nonisolated static func wireBitrateKbps(dial: Int, codecMultiplier: Double, boost: Double, capKbps: Int) -> Int {
        let scaled = Double(dial) * codecMultiplier * boost
        return min(max(5_000, Int(scaled.rounded())), capKbps)
    }

    // MARK: Streaming

    var defaultAppName: String {
        if let host = selectedHost,
           host.apps.contains(where: { $0.name == defaultLaunchApp }) {
            return defaultLaunchApp
        }
        return "Desktop"
    }

    func streamDefaultApp() {
        guard let host = selectedHost else { return }
        let app = host.apps.first(where: { $0.name == defaultAppName })
            ?? host.apps.first(where: { $0.name == "Desktop" })
            ?? host.apps.first
        if let app { requestStream(app: app, on: host) }
    }

    // MARK: - Hero verb (state-aware primary action)

    /// The app the host is running right now, when a fresh /serverinfo
    /// snapshot names one that is in the applist. Host truth is the one thing
    /// allowed to override the Default action: the button then restarts it.
    var resumableAppName: String? {
        guard let host = selectedHost, let live = hostLiveStatus,
              Date().timeIntervalSince(live.capturedAt) <= HostLiveStatus.stale,
              case .streamingApp(let name) = live.state,
              host.apps.contains(where: { $0.name == name }) else { return nil }
        return name
    }

    /// What the hero button launches: the host's running app if there is one,
    /// else the Default action from Settings (the menu bar uses the same rule).
    /// The AppIconsRow accent ring follows this so it never disagrees.
    var heroTargetAppName: String {
        resumableAppName ?? defaultAppName
    }

    /// Primary-button copy. Always "Stream <app>": every stream is a fresh
    /// /launch, and an app already running on the PC is quit first
    /// (`launchWithBusyRecovery`), so there is no resume to name.
    var heroActionLabel: String {
        "Stream \(heroTargetAppName)"
    }

    /// Launch the hero target (the primary click / Return-key action).
    func streamHeroApp() {
        guard let host = selectedHost else { return }
        if let name = resumableAppName,
           let app = host.apps.first(where: { $0.name == name }) {
            requestStream(app: app, on: host)
        } else {
            streamDefaultApp()
        }
    }

    /// Bridge our published quality settings into the engine's StreamConfig.
    /// The codec set is `offeredVideoFormats(for:)`; Automatic negotiates
    /// AV1 → HEVC → H.264 against what the host can actually encode.
    func nativeStreamConfig(for host: Host) -> StreamConfig {
        persistQualitySettings()
        var cfg = StreamConfig(width: effectiveWidth, height: effectiveHeight,
                               fps: effectiveFPS, bitrateKbps: effectiveBitrateKbps)
        cfg.captureSysKeys = captureSysKeys
        // The notch choice only means something on a notched panel; elsewhere
        // the session always takes the borderless cover (see
        // effectiveStreamCoversNotch for the issue this closes).
        cfg.coversNotch = effectiveStreamCoversNotch
        cfg.displayMode = effectiveDisplayMode
        cfg.videoFormats = offeredVideoFormats(for: host)
        // Codec-aware wire budget (see wireBitrateKbps): the H.264-anchored dial
        // scaled by the negotiated codec's efficiency. The spec chip reads the same
        // path so what's shown matches what's sent.
        let routeAsk = routeAskKbps(forFormats: cfg.videoFormats)
        cfg.bitrateKbps = StreamPathMTU.wifiAskKbps(ask: routeAsk, phyRateMbps: hostRoute.wifiPhyRateMbps)
        if cfg.bitrateKbps < routeAsk, let phy = hostRoute.wifiPhyRateMbps {
            Diag.notice("Wi-Fi link gate: the radio's PHY rate is \(Int(phy)) Mbps, asking for "
                + "\(cfg.bitrateKbps / 1000) Mbps instead of \(routeAsk / 1000).", "Stream")
        }
        let decision = bitrateDecision(forFormats: cfg.videoFormats)
        cfg.bitrateDecision = decision
        cfg.bitrateBoost = Self.rttWithdrawableBoost(decision, route: hostRoute.routeClass)
        return cfg
    }

    /// Title for the Window-mode stream window: the PC's name, then the app
    /// when one is known - "Tower - Desktop". Static and pure so the shape is
    /// trivially checkable.
    static func streamWindowTitle(hostName: String, appName: String) -> String {
        let app = appName.trimmingCharacters(in: .whitespaces)
        return app.isEmpty ? hostName : "\(hostName) - \(app)"
    }

    /// Convert a paired Host into the engine's ServerInfo. The
    /// serverCertPEM seeds TLS pinning so we don't have to re-discover it
    /// over HTTP first. We prefer Glimmer's own persisted pin (written by
    /// `PairingClient.runPairingFlow` after the RSA-verified handshake) over
    /// the moonlight-qt migrated copy. Both are equivalent pairing outputs,
    /// but only the Glimmer-side pin has been validated by our pairing flow
    /// in this app's lifetime. Internal so HostStatusPoller.swift can call it.
    func nativeServerInfo(for host: Host) -> ServerInfo {
        var info = ServerInfo(
            address: host.localAddress ?? host.manualAddress ?? host.name,
            uniqueId: host.id,
            serverName: host.displayName
        )
        // The pin file our pairing flow writes is the only pin source. The
        // legacy `host.serverCertPEM` copy (hosts.N.srvcert) is just a one-way
        // migration hint, and a mismatch between the two forces a re-pair.
        info.serverCertPEM = authoritativePin(for: host)
        info.appVersion = host.appVersion
        info.gfeVersion = host.gfeVersion
        info.pairStatus = .paired      // host is in our local list → already paired
        return info
    }

    /// Resolve the host's TLS pin from the authoritative file store, honoring
    /// the legacy UserDefaults hint (`host.serverCertPEM`) only as a one-way
    /// migration source. File ALWAYS wins; a file-vs-hint mismatch is a hard
    /// error (refuse + force re-pair), never a silent fallback. Returns nil
    /// when no trustworthy pin exists - the pairStatus gate then forces a
    /// re-pair rather than pinning a writable value.
    private func authoritativePin(for host: Host) -> String? {
        let filePin = PinnedCertStore.load(forHostID: host.id)
        let hint = host.serverCertPEM.flatMap { $0.isEmpty ? nil : $0 }

        if let filePin {
            // File wins. If the writable hint disagrees, someone moved one of
            // them - refuse to stream and force a re-pair rather than guess.
            if let hint, hint != filePin {
                log.error(
                    """
                    Pinned cert for host id=\(host.id, privacy: .public) DISAGREES with the \
                    UserDefaults hint - refusing to stream and forcing re-pair (possible MITM).
                    """
                )
                return nil
            }
            return filePin
        }

        // No file pin. Migrate the untrusted hint into the file store ONCE,
        // then read it back from the file store so every later read is
        // file-only. If the migration write fails, refuse rather than pin a
        // same-UID-writable value.
        if let hint {
            do {
                try PinnedCertStore.store(pem: hint, forHostID: host.id)
                return PinnedCertStore.load(forHostID: host.id)
            } catch {
                log.error(
                    """
                    Failed to migrate the UserDefaults cert hint into the file store for host \
                    id=\(host.id, privacy: .public): \(error.localizedDescription, privacy: .public) - \
                    forcing re-pair instead of pinning a writable value.
                    """
                )
                return nil
            }
        }

        // Neither store has a pin: stream falls to a forced re-pair (the
        // pairStatus gate handles it), not TOFU on a writable cert.
        log.error(
            """
            No pinned cert for host id=\(host.id, privacy: .public) - forcing re-pair. \
            Check that host.id matches server.uniqueId (the host's `<uniqueid>` from /serverinfo).
            """
        )
        return nil
    }
}
