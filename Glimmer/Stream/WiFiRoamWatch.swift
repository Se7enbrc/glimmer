//
//  WiFiRoamWatch.swift
//
//  Logs a breadcrumb when the Mac changes access point (BSSID) or its Wi-Fi
//  link drops and returns during a stream, so a hitch that lines up with one
//  explains itself in the log. Event-driven through CoreWLAN: nothing runs
//  between events.
//

import CoreWLAN
import Foundation

final class WiFiRoamWatch: NSObject, CWEventDelegate, @unchecked Sendable {
    static let shared = WiFiRoamWatch()

    private let client = CWWiFiClient.shared()
    /// Main actor only (start/stop are called from the stream lifecycle hooks).
    private var active = false

    @MainActor func start() {
        guard !active else { return }
        client.delegate = self
        do {
            try client.startMonitoringEvent(with: .bssidDidChange)
            try client.startMonitoringEvent(with: .linkDidChange)
            active = true
        } catch {
            Diag.info("Wi-Fi roam watch unavailable: \(error.localizedDescription)", "Stream")
        }
    }

    @MainActor func stop() {
        guard active else { return }
        try? client.stopMonitoringEvent(with: .bssidDidChange)
        try? client.stopMonitoringEvent(with: .linkDidChange)
        client.delegate = nil
        active = false
    }

    /// A same-access-point reconnect never changes the BSSID; this catches it.
    func linkDidChangeForWiFiInterface(withName interfaceName: String) {
        let interface = client.interface(withName: interfaceName)
        let up = (interface?.rssiValue() ?? 0) != 0 || (interface?.transmitRate() ?? 0) != 0
        Diag.notice(up ? "Wi-Fi link is back up (\(interfaceName))."
                       : "Wi-Fi link went down (\(interfaceName)): the Mac lost its access point; expect a gap until it is back.",
                    "Stream")
    }

    func bssidDidChangeForWiFiInterface(withName interfaceName: String) {
        let interface = client.interface(withName: interfaceName)
        let channel = interface?.wlanChannel()
        let band = channel.flatMap { WiFiTelemetry.bandLabel($0.channelBand) } ?? "unknown band"
        let number = channel?.channelNumber ?? 0
        let rssi = interface?.rssiValue() ?? 0
        Diag.notice("Wi-Fi roamed to another access point: now \(band) channel \(number), \(rssi) dBm. "
            + "A roam costs about a second of dead air; a hitch right here is the network.", "Stream")
    }
}
