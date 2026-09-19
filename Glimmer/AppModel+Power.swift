//
//  AppModel+Power.swift
//
//  Wake and Connect: send Wake-on-LAN packets for the selected PC, wait for
//  Sunshine to answer, then launch. Per-PC "Wake on LAN" gates it; the state
//  the button reads (waking, last failure) lives here.
//

import Foundation

extension AppModel {
    private static var wakeTask: Task<Void, Never>?
    static let wakeBudgetSeconds: Double = 90

    /// The PC opted in and Sunshine has told us its network address.
    func canWake(_ host: Host) -> Bool {
        host.wakeOnLAN && WakeOnLAN.normalizeMac(host.macAddress) != nil
    }

    func isWaking(_ host: Host) -> Bool { wakingHostID == host.id }

    /// Three bursts a second apart cover a NIC that misses the first packet;
    /// then Sunshine gets the wake budget to come up before we give up.
    func wakeHost(_ host: Host, thenConnect: Bool) {
        guard let mac = WakeOnLAN.normalizeMac(host.macAddress) else { return }
        Self.wakeTask?.cancel()
        wakingHostID = host.id
        wakeFailedHostID = nil
        hostStatusTask?.cancel()
        hostStatusTask = nil
        Self.wakeTask = Task { @MainActor in
            defer {
                if wakingHostID == host.id { wakingHostID = nil }
                restartHostStatusPolling()
            }
            let addresses = [host.localAddress, host.manualAddress]
            for burst in 0..<3 {
                let sent = await Task.detached(priority: .userInitiated) {
                    WakeOnLAN.send(mac: mac, hostAddresses: addresses)
                }.value
                Diag.notice("Wake on LAN: burst \(burst + 1), \(sent) packets for \(host.displayName)", "Power")
                if sent == 0 { break }
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            if await waitForSunshine(host: host, budgetSeconds: Self.wakeBudgetSeconds) {
                Diag.notice("Wake on LAN: \(host.displayName) is answering", "Power")
                guard thenConnect, !Task.isCancelled, selectedHost?.id == host.id, !isStreaming else { return }
                streamHeroApp()
            } else if !Task.isCancelled {
                Diag.notice("Wake on LAN: \(host.displayName) did not answer within \(Int(Self.wakeBudgetSeconds)) s", "Power")
                wakeFailedHostID = host.id
            }
        }
    }

    /// Drops our wait only; the packets are already on the wire.
    func cancelWake(_ host: Host) {
        guard wakingHostID == host.id else { return }
        Diag.notice("Wake on LAN: stopped waiting for \(host.displayName)", "Power")
        Self.wakeTask?.cancel()
        Self.wakeTask = nil
        wakingHostID = nil
        restartHostStatusPolling()
    }

    /// Sunshine's /serverinfo every 3 s until it answers or the budget ends;
    /// this polls the app, not the power state.
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
