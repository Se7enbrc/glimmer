//
//  WiFiTelemetry.swift
//
//  The LINK-HONESTY pair for the telemetry rig: the Wi-Fi ASSOCIATION sampler
//  (`WiFiTelemetry`) and the stream-ROUTE probe (`StreamRouteProbe`). Two
//  different questions, kept side by side because conflating them is an easy
//  and costly mistake:
//    * wifi_* fields = "what is the associated Wi-Fi radio doing?" - RSSI,
//      negotiated tx/PHY rate, noise floor, channel/band labels. These describe
//      the RADIO, whether or not the stream rides it.
//    * stream_link / stream_if = "which interface do the stream's packets
//      actually traverse?" - a kernel-routing probe. A docked laptop streams
//      over Thunderbolt Ethernet while STAYING associated to its AP, so
//      wifi_link:"wifi" on every row of a wired session is truthful about the
//      radio yet dead wrong as a route label (route identity would otherwise
//      have to be reconstructed post-hoc from RTT physics). stream_link is the
//      field that GATES the env-signal adaptive layer - radio evidence arms only
//      when the stream really is on the radio.
//
//  GATING + HOT-PATH SAFETY (load-bearing - see TelemetryExporter.swift):
//    * Sampled ONLY on the exporter's ~1Hz capture tick, on its serial queue -
//      NEVER the hot path. There is no per-frame and no per-packet cost.
//    * When telemetry is off (default), the exporter never exists, so this is
//      never constructed and never called: zero overhead.
//    * `CWWiFiClient.shared()` + one `interface()` read per tick is a cheap
//      framework call (no scan triggered - we read the CURRENT association, never
//      `scanForNetworks`, which WOULD disrupt the link). Wrapped so any CoreWLAN
//      hiccup degrades to "no sample" rather than affecting the stream.
//
//  WIRED HANDLING: on Ethernet (or any host with no associated Wi-Fi interface)
//  there is no radio to report, so we emit a clear `wired`/`unassociated` STATE
//  (an enum the renderer turns into a single `glimmer_wifi_link_state` gauge + a
//  `link="wired"` label) and omit the RSSI/rate/noise gauges entirely - an absent
//  signal series is the honest representation of "there is no radio here", and the
//  state gauge means a dashboard can still distinguish "wired" from "telemetry
//  off". This is what lets a reader say "the link was fine, the regression is
//  ours" (or vice-versa) instead of guessing.
//
//  SECRET-FREE: RSSI/rate/noise are radio physics; SSID/channel/band are the
//  user's OWN network identity on their OWN machine, carried only in the local
//  opt-in diagnostics (same trust boundary as the rest of the rig - local,
//  single-user, ephemeral). No host credentials, keys, or pairing material.
//

import Foundation
import CoreWLAN
import Network
import Darwin

/// One ~1Hz Wi-Fi radio sample. Plain value type, built on the exporter's serial
/// queue from `WiFiTelemetry.sample()`; rendered to both wire forms. All radio
/// fields are nil in the `wired`/`unassociated` states (no radio to report).
struct WiFiSnapshot: Sendable {

    /// Why the radio fields may be absent - turned into a single
    /// `glimmer_wifi_link_state` gauge (ordinal) + a `link` label so a dashboard
    /// can tell "wired" apart from "telemetry never sampled". NOTE this is the
    /// ASSOCIATION state of the default Wi-Fi interface, NOT the stream route -
    /// `associated` on a docked laptop streaming over Ethernet is truthful
    /// about the radio. The route lives in `stream_link` (StreamRouteProbe).
    enum LinkState: Int, Sendable {
        /// An associated Wi-Fi interface with live RSSI/rate/noise.
        case associated = 0
        /// A Wi-Fi interface exists but isn't associated to an AP (between
        /// networks, radio off) - no usable RSSI/rate.
        case unassociated = 1
        /// No Wi-Fi interface at all - the host is on Ethernet (or has no Wi-Fi
        /// hardware). The streaming path is wired; the radio is irrelevant.
        case wired = 2

        var label: String {
            switch self {
            case .associated: return "wifi"
            case .unassociated: return "unassociated"
            case .wired: return "wired"
            }
        }
    }

    var linkState: LinkState

    // ---- Radio physics (nil unless `associated`) ----
    /// Received signal strength, dBm (negative; closer to 0 = stronger). The
    /// headline "how good is the radio" number - a sag here that lines up with a
    /// stream hitch points the finger at the link, not the pipeline.
    var rssiDbm: Int?
    /// Negotiated PHY / transmit rate, Mbps. The ceiling the radio is currently
    /// willing to clock at - drops here precede the bitrate the host can sustain.
    var txRateMbps: Double?
    /// Noise floor, dBm (negative). RSSI − noise is the effective SNR; a rising
    /// noise floor (interference) degrades throughput even at a steady RSSI.
    var noiseDbm: Int?

    // ---- Labels (nil when unavailable) ----
    /// The associated network name. nil on macOS 14+ without Location
    /// authorization (the OS gates SSID behind location) - the band/channel still
    /// resolve, so we degrade to those rather than failing the whole sample.
    var ssid: String?
    /// Channel number on the current band.
    var channel: Int?
    /// "2.4GHz" / "5GHz" / "6GHz" - the band label, the single most useful split
    /// for a quick "is this the congested 2.4 radio" read.
    var band: String?
}

/// CoreWLAN-backed sampler. Stateless aside from a cached `CWWiFiClient` (the
/// singleton CoreWLAN itself vends). Constructed by the exporter only when the
/// gate is on; `sample()` is called once per ~1Hz tick on the exporter queue.
///
/// `@unchecked Sendable`: `CWWiFiClient`/`CWInterface` are not annotated Sendable
/// by the SDK, but we only ever touch them from the exporter's single serial
/// queue (one caller, one thread), so the access is serialized by construction.
final class WiFiTelemetry: @unchecked Sendable {

    private let client = CWWiFiClient.shared()

    /// Capture one radio sample. Reads the CURRENT association only - never
    /// triggers a scan (which would disrupt the link). Any CoreWLAN failure or a
    /// missing interface degrades to a `wired`/`unassociated` state, so a probe
    /// hiccup can never affect the stream.
    func sample() -> WiFiSnapshot {
        // No default Wi-Fi interface ⇒ the host has no Wi-Fi radio in play (pure
        // Ethernet, or no Wi-Fi hardware): report `wired`, omit the radio gauges.
        guard let interface = client.interface() else {
            return WiFiSnapshot(linkState: .wired)
        }

        // An interface with no SSID *and* no usable rate is "present but not
        // associated" - between networks or radio disabled. An ASSOCIATED radio
        // while STREAMING over Ethernet is the common docked-laptop case: this
        // sampler keeps reporting the radio truthfully (it IS associated), and
        // `StreamRouteProbe` is what says which interface the stream rides.
        let rssi = interface.rssiValue()       // 0 when not associated
        let phyRate = interface.transmitRate() // 0.0 when not associated
        let associated = rssi != 0 || phyRate != 0
        guard associated else {
            return WiFiSnapshot(linkState: .unassociated)
        }

        var snap = WiFiSnapshot(linkState: .associated)
        snap.rssiDbm = rssi
        // transmitRate is already in Mbps. Treat a 0 as "unknown" (omit) so a
        // momentary read gap doesn't render as a 0Mbps cliff.
        snap.txRateMbps = phyRate > 0 ? phyRate : nil
        // noiseMeasurement is dBm; 0 is the "no measurement" sentinel CoreWLAN
        // returns when the driver doesn't surface a floor.
        let noise = interface.noiseMeasurement()
        snap.noiseDbm = noise != 0 ? noise : nil

        // SSID is nil on macOS 14+ without Location authorization - that's fine,
        // the band/channel still resolve and carry the AP identity we need most.
        snap.ssid = interface.ssid()
        if let channel = interface.wlanChannel() {
            snap.channel = channel.channelNumber
            snap.band = Self.bandLabel(channel.channelBand)
        }
        return snap
    }

    /// Map CoreWLAN's `CWChannelBand` to a compact dashboard label.
    private static func bandLabel(_ band: CWChannelBand) -> String? {
        switch band {
        case .band2GHz: return "2.4GHz"
        case .band5GHz: return "5GHz"
        case .band6GHz: return "6GHz"
        case .bandUnknown: return nil
        @unknown default: return nil
        }
    }
}

// MARK: - Stream-route probe (which interface the stream ACTUALLY rides)

/// One probed stream-route classification: the interface the kernel routes the
/// stream's packets toward, and its wired/wifi/tunnel class. Built on the
/// probe's serial queue; read by the exporter at 1Hz (`stream_link` /
/// `stream_if` NDJSON fields).
struct StreamRouteSnapshot: Sendable {
    /// "wired" | "wifi" | "tunnel" | "unknown". `unknown` = the probe could not
    /// resolve a route (no host latched, sockaddr build failed, or no interface
    /// matched) - absent knowledge stays labelled as such, never guessed.
    var linkLabel: String = "unknown"
    /// BSD interface name the route resolved to ("en0", "en12", "utun4"...), nil
    /// when the probe failed. Carried so a hot-undock ("en12 vanished") is
    /// attributable from the NDJSON alone.
    var interfaceName: String?
}

/// Probes the route the stream's UDP packets actually take: a throwaway
/// connected UDP socket to the host (connect() on UDP sends NOTHING - it only
/// asks the kernel to bind a route) → `getsockname()` for the kernel-chosen
/// local address → `getifaddrs()` match → interface name → classify via
/// `CWWiFiClient.interfaceNames()` (utun*/ipsec* → tunnel, awdl*/llw* → the
/// Wi-Fi radio's P2P face). Re-probes on every `NWPathMonitor` change (the
/// mid-session hot-undock case) plus a lazy 15s revalidation, and emits a
/// `route_change` EVENT row + Diag NOTICE on every classification flip.
///
/// GATING + HOT-PATH SAFETY (the WiFiTelemetry contract): constructed ONLY by
/// the exporter (gate-on path), all probing on its own utility queue - never a
/// hot path, a handful of cheap syscalls per probe, no DNS (the host address is
/// the IP literal RTSP already resolved; a hostname degrades to `unknown` with
/// a NOTICE rather than a blocking lookup). The always-live cost when telemetry
/// is off is exactly one latched String per connect.
final class StreamRouteProbe: @unchecked Sendable {

    // ---- Host latch (always-live, written at the CONNECT edge) ----
    //
    // The exporter is constructed long after the session knows its host, and
    // threading the address through TelemetrySource just for this would touch
    // every construction site - so the connect edge latches it here instead
    // (the `FrameTimingTracker.shared` install/clear discipline: one writer at
    // a rare lifecycle edge, read once at exporter construction).
    nonisolated(unsafe) private static var latchedHost: String?
    private static let hostLatchLock = NSLock()

    /// Latch the host address for the session being connected. Called at the
    /// connect-start edge (StreamSession), BEFORE the exporter exists.
    static func latchHost(_ address: String) {
        hostLatchLock.lock(); latchedHost = address; hostLatchLock.unlock()
    }

    /// The host latched for the session being connected (nil before the first
    /// connect this process run). Read by the audio cushion memory at decoder
    /// init - the host half of its per-host+link UserDefaults seed key. The
    /// value stays LOCAL (preferences key only); it never rides telemetry or
    /// logs (the secret-free contract).
    static var currentLatchedHost: String? {
        hostLatchLock.lock(); defer { hostLatchLock.unlock() }
        return latchedHost
    }

    // ---- Instance state ----

    /// Re-probes + the path monitor run here; `current()` reads the lock-guarded
    /// snapshot from the exporter queue, so no probe ever blocks a capture tick.
    private let queue = DispatchQueue(label: "io.ugfugl.Glimmer.telemetry.route", qos: .utility)
    private var monitor: NWPathMonitor?
    private let stateLock = NSLock()
    private var snapshot = StreamRouteSnapshot()
    private var lastProbeNanos: UInt64 = 0
    /// True once a snapshot exists, so the first probe logs a NOTICE but never
    /// emits a `route_change` (there is no previous route to change FROM).
    private var hasProbed = false
    /// Sensor-honesty contract: the first probe failure is logged ONCE naming
    /// the failing stage (the IOReport dev-works/packaged-dark precedent).
    private var loggedFailure = false

    /// The host's sockaddr, resolved ONCE at construction from the latched IP
    /// literal (no DNS, ever - see the class doc). nil = probe can't run.
    private var destAddr: sockaddr_storage?
    private var destLen: socklen_t = 0
    private var family: Int32 = AF_INET

    /// The port is irrelevant to route selection (connect() on UDP only picks
    /// the egress interface), so the discard port keeps the intent obvious.
    private static let probePort: UInt16 = 9

    /// Staleness horizon for the lazy revalidation: `NWPathMonitor` catches the
    /// real transitions; this only backstops a missed callback.
    private static let revalidateNanos: UInt64 = 15_000_000_000

    init() {
        Self.hostLatchLock.lock()
        let host = Self.latchedHost
        Self.hostLatchLock.unlock()
        if let host, let (dest, len, fam) = UdpPinger.makeSockaddr(
            for: NWEndpoint.Host(host), port: Self.probePort) {
            destAddr = dest
            destLen = len
            family = fam
        }
    }

    /// Arm the probe: take the first sample (the first-sample NOTICE the sensor
    /// contract requires) and start the path monitor. Called from the exporter's
    /// `start()`; everything lands on this probe's own queue.
    func start() {
        queue.async { [weak self] in self?.probeAndPublish() }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            // Path changes fire for ANY route-table event (dock/undock, VPN up,
            // Wi-Fi join) - re-probe each time; the change-detection below
            // dedupes, so a same-route update costs a few syscalls and no row.
            self?.probeAndPublish()
        }
        monitor.start(queue: queue)
        self.monitor = monitor
    }

    /// Stop the path monitor. Idempotent; called from the exporter's `stop()`.
    func stop() {
        monitor?.cancel()
        monitor = nil
    }

    /// The latest route snapshot for this capture tick. Lock-guarded read; if
    /// the sample has gone stale (missed path callback) a revalidation is
    /// SCHEDULED on the probe queue - never run inline on the exporter tick.
    func current() -> StreamRouteSnapshot {
        stateLock.lock()
        let snap = snapshot
        let stale = DispatchTime.now().uptimeNanoseconds &- lastProbeNanos > Self.revalidateNanos
        stateLock.unlock()
        if stale { queue.async { [weak self] in self?.probeAndPublish() } }
        return snap
    }

    /// One probe → classify → publish, emitting the `route_change` EVENT +
    /// NOTICE when the classification flipped. On `queue` only.
    private func probeAndPublish() {
        let name = probeInterfaceName()
        let fresh = StreamRouteSnapshot(
            linkLabel: Self.classify(interfaceName: name), interfaceName: name)

        stateLock.lock()
        let previous = snapshot
        let isFirst = !hasProbed
        hasProbed = true
        snapshot = fresh
        lastProbeNanos = DispatchTime.now().uptimeNanoseconds
        stateLock.unlock()

        let ifLabel = fresh.interfaceName ?? "?"
        if isFirst {
            // First-sample NOTICE (success or failure) - the sensor-honesty
            // contract every sampler ships with.
            Diag.notice("Stream route probe: \(fresh.linkLabel) via \(ifLabel)",
                        TelemetryExporter.logCategory)
        } else if fresh.linkLabel != previous.linkLabel
                    || fresh.interfaceName != previous.interfaceName {
            Diag.notice("Stream ROUTE CHANGE: \(previous.linkLabel)/\(previous.interfaceName ?? "?") "
                + "→ \(fresh.linkLabel)/\(ifLabel)", TelemetryExporter.logCategory)
            // Also bump the Prometheus counter so a wake-on-different-AP is visible
            // in Prometheus, not only the NDJSON/Loki event below. Same detection.
            TelemetryCounters.shared.routeChangeTotal.increment()
            TelemetryExporter.recordEvent([
                "\"event\":\"route_change\"",
                "\"stream_link\":\"\(fresh.linkLabel)\"",
                "\"stream_if\":\"\(TelemetryRenderer.jsonStringEscape(ifLabel))\"",
                "\"prev_stream_link\":\"\(previous.linkLabel)\"",
                "\"prev_stream_if\":\"\(TelemetryRenderer.jsonStringEscape(previous.interfaceName ?? "?"))\""
            ])
        }
    }

    /// connect() + getsockname() + getifaddrs() → the egress interface name, or
    /// nil with a one-time stage-naming NOTICE on the first failure.
    private func probeInterfaceName() -> String? {
        guard var dest = destAddr, destLen > 0 else {
            noteFailureOnce("no probe address (host not latched or not an IP literal)")
            return nil
        }
        let fd = socket(family, SOCK_DGRAM, 0)
        guard fd >= 0 else {
            noteFailureOnce("socket() errno \(errno)")
            return nil
        }
        defer { close(fd) }
        let connected = withUnsafePointer(to: &dest) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, destLen) == 0
            }
        }
        guard connected else {
            // EHOSTUNREACH/ENETDOWN here is itself signal: the route to the
            // host is GONE (mid-undock window) - honest answer is unknown.
            noteFailureOnce("connect() errno \(errno)")
            return nil
        }
        var local = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let got = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len) == 0
            }
        }
        guard got else {
            noteFailureOnce("getsockname() errno \(errno)")
            return nil
        }
        guard let name = Self.interfaceName(matching: local) else {
            noteFailureOnce("no getifaddrs match for the kernel-chosen local address")
            return nil
        }
        return name
    }

    private func noteFailureOnce(_ stage: String) {
        stateLock.lock()
        let logged = loggedFailure
        loggedFailure = true
        stateLock.unlock()
        guard !logged else { return }
        Diag.notice("Stream route probe unavailable - \(stage); stream_link=unknown "
            + "(radio fields unaffected)", TelemetryExporter.logCategory)
    }

    /// Walk getifaddrs for the interface owning `local`'s address. Family +
    /// address-bytes match; the port is ignored (ephemeral).
    private static func interfaceName(matching local: sockaddr_storage) -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            guard let addr = ifa.pointee.ifa_addr,
                  addr.pointee.sa_family == local.ss_family,
                  sameAddress(addr, local) else { continue }
            return String(cString: ifa.pointee.ifa_name)
        }
        return nil
    }

    /// Compare the address bytes of one getifaddrs entry against the probed
    /// local address. Raw byte offsets (sin_addr at +4, sin6_addr at +8) avoid
    /// re-binding the C structs just to read 4/16 bytes.
    private static func sameAddress(_ ifaceAddr: UnsafePointer<sockaddr>,
                                    _ local: sockaddr_storage) -> Bool {
        var localCopy = local
        return withUnsafeBytes(of: &localCopy) { localRaw -> Bool in
            guard let localBase = localRaw.baseAddress else { return false }
            let ifaceRaw = UnsafeRawPointer(ifaceAddr)
            switch Int32(local.ss_family) {
            case AF_INET:
                return memcmp(ifaceRaw + 4, localBase + 4, 4) == 0
            case AF_INET6:
                return memcmp(ifaceRaw + 8, localBase + 8, 16) == 0
            default:
                return false
            }
        }
    }

    /// Interface name → link class. CoreWLAN owns the wifi answer (it lists the
    /// WLAN interfaces by name); awdl/llw are the same radio's P2P/low-latency
    /// faces; utun/ipsec/ppp are tunnels (a Tailscale path reads "tunnel",
    /// honestly - the radio underneath is NOT what the kernel routed to).
    /// Everything else that routes (en*, bridge*) is wired.
    private static func classify(interfaceName: String?) -> String {
        guard let name = interfaceName else { return "unknown" }
        if let wifiNames = CWWiFiClient.interfaceNames(), wifiNames.contains(name) { return "wifi" }
        if name.hasPrefix("awdl") || name.hasPrefix("llw") { return "wifi" }
        if name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp") { return "tunnel" }
        return "wired"
    }
}
