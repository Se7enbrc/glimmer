// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import Network

public enum HostAddressRecovery {
    /// Only a private IPv4 lease moves; names and explicit remote routes remain the player's choice.
    public static func canHeal(_ address: String) -> Bool {
        guard let raw = IPv4Address(address)?.rawValue else { return false }
        let octets = Array(raw)
        let (first, second) = (octets[0], octets[1])
        return first == 10 || (first == 172 && (16...31).contains(second))
            || (first == 192 && second == 168) || (first == 169 && second == 254)
    }

    public static func find(_ server: ServerInfo, within seconds: Double = 10,
                            makeNetwork: @escaping @Sendable (ServerInfo) -> NetworkClient) async -> ServerInfo? {
        guard canHeal(server.address), server.serverCertPEM != nil, !Task.isCancelled else { return nil }
        let discovery = HostDiscovery(ipv4Only: true)
        let session = await discovery.start()
        let result = await withTaskGroup(of: ServerInfo?.self) { group in
            group.addTask {
                await search(server, updates: session.stream) { probe in
                    let client = makeNetwork(probe)
                    let answer = try? await client.fetchServerInfo(requiredUniqueId: server.uniqueId)
                    await client.shutdown()
                    return answer
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next()
            group.cancelAll()
            return first.flatMap { $0 }
        }
        await discovery.stop()
        return Task.isCancelled ? nil : result
    }

    package static func search(_ server: ServerInfo, updates: AsyncStream<HostDiscovery.Update>,
                               authenticate: @Sendable (ServerInfo) async -> ServerInfo?) async -> ServerInfo? {
        guard canHeal(server.address), server.serverCertPEM != nil, !server.uniqueId.isEmpty else { return nil }
        for await found in updates {
            for address in Set(found.hosts.map(\.host)) where address != server.address && IPv4Address(address) != nil {
                guard !Task.isCancelled else { return nil }
                var probe = server
                probe.address = address
                let answer = await authenticate(probe)
                guard !Task.isCancelled else { return nil }
                if answer?.uniqueId == server.uniqueId { return probe }
            }
        }
        return nil
    }
}
