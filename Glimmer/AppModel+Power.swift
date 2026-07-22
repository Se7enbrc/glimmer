//
//  AppModel+Power.swift
//
//  Luna power-action orchestration (spec: docs/LUNA_POWER.md). The GATE and
//  the subprocess mechanics live in LunaPower.swift; this file owns the UX
//  flows: Wake / Wake & Connect from an offline tile, and the online power
//  verbs from the tile's power menu. Everything runs off the main thread via
//  LunaPower's runner; the UI stays live through the ~36s confirmed wake.
//

import Foundation

extension AppModel {

    /// Wake the host via luna (exit 0 = CONFIRMED awake, ~36s cold - no
    /// client-side power polling on top), then optionally wait for Sunshine to
    /// answer /serverinfo and start the default app - "as if the user had
    /// tapped the host". The host's encoder is known-ragged for ~15s after a
    /// cold boot (Sunshine ramp); early jitter is not failure.
    func wakeHost(_ host: Host, device: LunaPower.Device, thenConnect: Bool) {
        Task { @MainActor in
            do {
                try await LunaPower.shared.perform("on", deviceID: device.id, hostID: host.id)
                Diag.notice("luna: \(host.displayName) confirmed awake", "Power")
                restartHostStatusPolling()
                guard thenConnect else { return }
                if await waitForSunshine(host: host, budgetSeconds: 90) {
                    guard selectedHost?.id == host.id, !isStreaming else { return }
                    streamDefaultApp()
                } else {
                    Diag.notice("luna: \(host.displayName) awake but Sunshine did not "
                        + "answer within 90s - not auto-connecting", "Power")
                }
            } catch {
                // LunaPower recorded lastActionError for the tile subtext.
                Diag.notice("luna: wake \(host.displayName) failed - "
                    + "\(error.localizedDescription)", "Power")
            }
        }
    }

    /// Run an online power verb (off / sleep / reboot) against the host, with
    /// the poller re-armed after so the tile converges to the real state
    /// (off ~9s confirmed; the chip then reads Asleep and the wake controls
    /// return via the same gate).
    func powerAction(_ verb: String, host: Host, device: LunaPower.Device) {
        Task { @MainActor in
            do {
                try await LunaPower.shared.perform(verb, deviceID: device.id, hostID: host.id)
                Diag.notice("luna: \(verb) \(host.displayName) confirmed", "Power")
            } catch {
                Diag.notice("luna: \(verb) \(host.displayName) failed - "
                    + "\(error.localizedDescription)", "Power")
            }
            restartHostStatusPolling()
        }
    }

    /// Bounded post-wake wait for Sunshine: the DEVICE is confirmed up (luna's
    /// synchronous contract), but Sunshine's HTTP front-end takes several more
    /// seconds to come up after the OS boots. 3s-cadence /serverinfo probes -
    /// this polls the APP layer, not the power state, so it does not violate
    /// the no-polling-on-top rule.
    private func waitForSunshine(host: Host, budgetSeconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(budgetSeconds)
        let info = nativeServerInfo(for: host)
        while Date() < deadline {
            let client = NetworkClient(server: info)
            let answered = (try? await client.fetchServerInfo()) != nil
            await client.shutdown()
            if answered { return true }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if Task.isCancelled { return false }
        }
        return false
    }
}
