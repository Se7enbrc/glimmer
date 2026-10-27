// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import Synchronization
import Testing
@testable import GlimmerEngine

struct HostAddressRecoveryTests {
    private func saved() -> ServerInfo {
        var value = ServerInfo(address: "192.168.1.20", uniqueId: "paired-pc", serverName: "Den PC")
        value.serverCertPEM = "fixture pin, never sent to a transport"
        return value
    }

    private func updates(_ addresses: [String]) -> AsyncStream<HostDiscovery.Update> {
        AsyncStream { continuation in
            for address in addresses {
                continuation.yield(.init(hosts: [.init(id: address, displayName: "Den PC", host: address,
                                                       port: 47989)], denied: false))
            }
            continuation.finish()
        }
    }

    @Test func everyCandidateUsesTheSavedPinAndIdentity() async throws {
        let server = saved()
        let probes = Mutex<[String]>([])
        let found = await HostAddressRecovery.search(server,
            updates: updates([server.address, "192.168.1.21", "192.168.1.22", "192.168.1.23"])) { probe in
            #expect(probe.serverCertPEM == server.serverCertPEM)
            #expect(probe.uniqueId == server.uniqueId)
            probes.withLock { $0.append(probe.address) }
            if probe.address == "192.168.1.21" { return nil }
            var answer = probe
            if probe.address == "192.168.1.22" { answer.uniqueId = "another-pc" }
            return answer
        }
        let moved = try #require(found)
        #expect(moved.address == "192.168.1.23")
        #expect(moved.serverCertPEM == server.serverCertPEM && moved.uniqueId == server.uniqueId)
        #expect(probes.withLock { $0 } == ["192.168.1.21", "192.168.1.22", "192.168.1.23"])
    }

    @Test func missingPinAndStableRoutesNeverProbeCandidates() async {
        var unpaired = saved()
        unpaired.serverCertPEM = nil
        var named = saved()
        named.address = "tower.local"
        for server in [unpaired, named] {
            let found = await HostAddressRecovery.search(server, updates: updates(["192.168.1.21"])) { _ in
                Issue.record("Untrusted or stable routes must not enter recovery")
                return nil
            }
            #expect(found == nil)
        }
    }

    @Test func cancellationDiscardsAnAuthenticatedResult() async {
        let server = saved()
        let task = Task {
            await HostAddressRecovery.search(server, updates: updates(["192.168.1.21"])) { probe in
                withUnsafeCurrentTask { $0?.cancel() }
                return probe
            }
        }
        #expect(await task.value == nil)
    }
}
