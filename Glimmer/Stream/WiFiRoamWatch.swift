//
//  WiFiRoamWatch.swift
//
//  Logs a breadcrumb when the Mac changes access point (BSSID) during a
//  stream, so a hitch that lines up with a roam explains itself in the log.
//  Event-driven through CoreWLAN: nothing runs between roams.
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
            active = true
        } catch {
            Diag.info("Wi-Fi roam watch unavailable: \(error.localizedDescription)", "Stream")
        }
    }

    @MainActor func stop() {
        guard active else { return }
        try? client.stopMonitoringEvent(with: .bssidDidChange)
        client.delegate = nil
        active = false
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
