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
        let formats = HostCodecPreference.load(for: host.id).apply(to: .probedSupported)
        return wireBitrateKbps(forFormats: formats)
    }

    /// The H.264-anchored quality dial (`effectiveBitrateKbps`) scaled by the
    /// negotiated codec's efficiency. The spec UI and `nativeStreamConfig` both read
    /// this so the shown bitrate can't drift from what's sent. Custom is verbatim.
    func wireBitrateKbps(forFormats formats: VideoFormats) -> Int {
        if case .custom = qualityPreset { return effectiveBitrateKbps }
        let mult = Self.codecBudgetMultiplier(for: formats)
        return max(5_000, Int((Double(effectiveBitrateKbps) * mult).rounded()))
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

    /// UserDefaults key for the NAME of the last app launched on a host.
    /// Distinct from `glimmer.lastConnected.<id>` (a DATE, stamped at stream
    /// END): "what did I play here" is true from the moment a launch begins,
    /// so the name stamps at START - see the write in `stream(app:on:)`.
    static func lastPlayedAppKey(for hostId: String) -> String {
        "glimmer.lastPlayedApp.\(hostId)"
    }

    /// The app the hero button can meaningfully resume on the selected host.
    /// Host-reported truth wins: a fresh /serverinfo snapshot naming an
    /// in-flight session (aged out on the same `HostLiveStatus.stale` horizon
    /// the readiness chip uses; the host-id guard in `publishLiveStatus`
    /// already scopes the snapshot to this host). Otherwise the name stamped
    /// at the last stream start, as long as it's still in the applist. nil
    /// when neither is known - the button falls back to "Connect".
    var resumableAppName: String? {
        guard let host = selectedHost else { return nil }
        if let live = hostLiveStatus,
           Date().timeIntervalSince(live.capturedAt) <= HostLiveStatus.stale,
           case .streamingApp(let name) = live.state,
           host.apps.contains(where: { $0.name == name }) {
            return name
        }
        if let last = UserDefaults.standard.string(forKey: Self.lastPlayedAppKey(for: host.id)),
           host.apps.contains(where: { $0.name == last }) {
            return last
        }
        return nil
    }

    /// What the hero button actually launches - the resume target when known,
    /// else the configured default app. The AppIconsRow accent ring follows
    /// this so the ring can never disagree with the button's verb.
    var heroTargetAppName: String {
        resumableAppName ?? defaultAppName
    }

    /// Primary-button copy. Always "Stream <app>" - this button only shows on the
    /// launcher (never mid-stream), so "Resume" read as confusing. The verb is the
    /// same whether we resume the host's running session or launch fresh;
    /// `streamHeroApp()` still picks /resume vs /launch under the hood.
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
    /// The codec set is the probed client capability capped by the host's
    /// override (right-click → Codec; Automatic by default, which negotiates
    /// AV1 → HEVC → H.264 against what the host can actually encode).
    func nativeStreamConfig(for host: Host) -> StreamConfig {
        persistQualitySettings()
        var cfg = StreamConfig(width: effectiveWidth, height: effectiveHeight,
                               fps: effectiveFPS, bitrateKbps: effectiveBitrateKbps)
        cfg.hdr = effectiveHDR
        cfg.captureSysKeys = captureSysKeys
        cfg.coversNotch = streamCoversNotch
        let codecPref = HostCodecPreference.load(for: host.id)
        cfg.videoFormats = codecPref.apply(to: .probedSupported)
        // Codec-aware wire budget (see wireBitrateKbps): the H.264-anchored dial
        // scaled by the negotiated codec's efficiency. The spec chip reads the same
        // path so what's shown matches what's sent.
        cfg.bitrateKbps = wireBitrateKbps(forFormats: cfg.videoFormats)
        return cfg
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
        // H1: the mode-0600 file store is the ONLY authoritative pin source.
        // `host.serverCertPEM` lives in same-UID-writable UserDefaults
        // (hosts.N.srvcert) - an attacker can swap it for a MITM cert via
        // cfprefsd, so we treat it as an untrusted HINT, never a direct pin.
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
