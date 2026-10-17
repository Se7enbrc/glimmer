// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

package struct WiFiSnapshot: Sendable {

    package init(
        linkState: LinkState,
        rssiDbm: Int? = nil,
        txRateMbps: Double? = nil,
        noiseDbm: Int? = nil,
        ssid: String? = nil,
        channel: Int? = nil,
        band: String? = nil
    ) {
        self.linkState = linkState
        self.rssiDbm = rssiDbm
        self.txRateMbps = txRateMbps
        self.noiseDbm = noiseDbm
        self.ssid = ssid
        self.channel = channel
        self.band = band
    }

    /// Why the radio fields may be absent - turned into a single
    /// `glimmer_wifi_link_state` gauge (ordinal) + a `link` label so a dashboard
    /// can tell "wired" apart from "telemetry never sampled". NOTE this is the
    /// ASSOCIATION state of the default Wi-Fi interface, NOT the stream route -
    /// `associated` on a docked laptop streaming over Ethernet is truthful
    /// about the radio. The route lives in `stream_link` (StreamRouteProbe).
    package enum LinkState: Int, Sendable {
        /// An associated Wi-Fi interface with live RSSI/rate/noise.
        case associated = 0
        /// A Wi-Fi interface exists but isn't associated to an AP (between
        /// networks, radio off) - no usable RSSI/rate.
        case unassociated = 1
        /// No Wi-Fi interface at all - the host is on Ethernet (or has no Wi-Fi
        /// hardware). The streaming path is wired; the radio is irrelevant.
        case wired = 2

        package var label: String {
            switch self {
            case .associated: return "wifi"
            case .unassociated: return "unassociated"
            case .wired: return "wired"
            }
        }
    }

    package var linkState: LinkState

    // ---- Radio physics (nil unless `associated`) ----
    /// Received signal strength, dBm (negative; closer to 0 = stronger). The
    /// headline "how good is the radio" number - a sag here that lines up with a
    /// stream hitch points the finger at the link, not the pipeline.
    package var rssiDbm: Int?
    /// Negotiated PHY / transmit rate, Mbps. The ceiling the radio is currently
    /// willing to clock at - drops here precede the bitrate the host can sustain.
    package var txRateMbps: Double?
    /// Noise floor, dBm (negative). RSSI − noise is the effective SNR; a rising
    /// noise floor (interference) degrades throughput even at a steady RSSI.
    package var noiseDbm: Int?

    // ---- Labels (nil when unavailable) ----
    /// The associated network name. nil on macOS 14+ without Location
    /// authorization (the OS gates SSID behind location) - the band/channel still
    /// resolve, so we degrade to those rather than failing the whole sample.
    package var ssid: String?
    /// Channel number on the current band.
    package var channel: Int?
    /// "2.4GHz" / "5GHz" / "6GHz" - the band label, the single most useful split
    /// for a quick "is this the congested 2.4 radio" read.
    package var band: String?
}

package struct StreamRouteSnapshot: Sendable {

    package init(
        linkLabel: String = "unknown",
        interfaceName: String? = nil
    ) {
        self.linkLabel = linkLabel
        self.interfaceName = interfaceName
    }

    /// "wired" | "wifi" | "tunnel" | "unknown". `unknown` = the probe could not
    /// resolve a route (no host latched, sockaddr build failed, or no interface
    /// matched) - absent knowledge stays labelled as such, never guessed.
    package var linkLabel: String = "unknown"
    /// BSD interface name the route resolved to ("en0", "en12", "utun4"...), nil
    /// when the probe failed. Carried so a hot-undock ("en12 vanished") is
    /// attributable from the NDJSON alone.
    package var interfaceName: String?
}
