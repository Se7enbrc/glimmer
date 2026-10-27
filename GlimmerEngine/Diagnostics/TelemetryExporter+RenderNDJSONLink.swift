// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

#if os(macOS)
// Route and radio facts stay separate so a wired stream can still report the associated Wi-Fi radio.

import Foundation

extension TelemetryRenderer {

    /// LINK fields. `stream_link`/`stream_if` name the interface the stream rides
    /// (it gates the env-signal layer); `wifi_*` describe the associated radio
    /// whether or not the stream uses it, so wired + wifi_link:"wifi" is normal.
    package static func ndjsonLink(
        _ builder: inout NDJSONBuilder, _ snap: TelemetrySnapshot, _ extras: TelemetrySnapshot.Extras
    ) {
        let streams = [("video", snap.receiveVideo), ("audio", snap.receiveAudio)]
        for (name, receive) in streams {
            builder.addCount("\(name)_rx_timestamp_samples", receive.samples)
            builder.addCount("\(name)_rx_timestamp_missing", receive.missing)
            builder.add("\(name)_rx_read_delay_max_ms", receive.delayMaxMs)
            builder.add("\(name)_rx_read_delay_p99_ms", receive.delayP99Ms)
            builder.add("\(name)_rx_kernel_gap_max_ms", receive.gapMaxMs)
            builder.add("\(name)_rx_kernel_gap_p99_ms", receive.gapP99Ms)
        }
        if let routeSnapshot = extras.streamRoute {
            builder.addString("stream_link", routeSnapshot.linkLabel)
            builder.addString("stream_if", routeSnapshot.interfaceName)
        }
        // Env-signal state + keepalive judge fields; transitions also get their
        // own `event:"env_state"` row with the evidence vector.
        builder.addInt("env_state", extras.envStateOrdinal)
        builder.addString("env_state_label", extras.envStateLabel)
        builder.addCount("env_state_changes_total", extras.envStateChangesTotal)
        builder.add("keepalive_interval_ms", extras.keepaliveIntervalMs)
        builder.addCount("pings_sent_video_total", extras.videoPingsSentTotal)
        builder.addCount("pings_sent_audio_total", extras.audioPingsSentTotal)
        builder.add("pings_video_per_s", extras.videoPingsPerSecond)
        builder.add("pings_audio_per_s", extras.audioPingsPerSecond)
        // Blackout attribution: was awdl0 parked, and did the kernel drop
        // datagrams at a full socket buffer (vs loss before the Mac)?
        builder.addBool("awdl_suppressing", snap.awdlSuppressing)
        builder.addCount("awdl_resuppress_total", snap.awdlReSuppressTotal)
        builder.addCount("udp_fullsock_delta", snap.udpFullSockDelta)
        guard let wifi = snap.wifi else { return }
        builder.addString("wifi_link", wifi.linkState.label)
        builder.addInt("wifi_rssi_dbm", wifi.rssiDbm)
        builder.add("wifi_tx_rate_mbps", wifi.txRateMbps)
        builder.addInt("wifi_noise_dbm", wifi.noiseDbm)
        builder.addString("wifi_ssid", wifi.ssid)
        builder.addInt("wifi_channel", wifi.channel)
        builder.addString("wifi_band", wifi.band)
    }
}

#endif
