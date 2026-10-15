// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import GlimmerEngine
import Synchronization
import UIKit

struct SavedPC: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let address: String
    let httpPort: Int
    let httpsPort: Int

    init(server: ServerInfo) {
        id = server.uniqueId
        name = server.serverName
        address = server.address
        httpPort = server.httpPort
        httpsPort = server.httpsPort
    }

    var server: ServerInfo {
        var server = ServerInfo(address: address, uniqueId: id, serverName: name)
        server.httpPort = httpPort
        server.httpsPort = httpsPort
        return server
    }
}

struct PreparedPC: Sendable {
    let network: NetworkClient
    let server: ServerInfo
}

final class ProtectedDataState: Sendable {
    private let available: Mutex<Bool>
    init(_ available: Bool) { self.available = Mutex(available) }
    func update(_ value: Bool) { available.withLock { $0 = value } }
    func read() -> Bool { available.withLock { $0 } }
}

@MainActor
final class LauncherServices {
    enum Failure: Error { case unavailable, missingPin, invalidIdentity }
    let protectedData: ProtectedDataState
    private let defaults: UserDefaults
    private let base: URL
    private let identity: IdentityManager
    private let deviceName: String
    private static let savedKey = "ios.savedPCs"
    private static let lastConnectedKey = "ios.lastConnectedPCID"

    init(defaults: UserDefaults = .standard, base: URL, protectedData: ProtectedDataState,
         deviceName: String = UIDevice.current.name) {
        self.defaults = defaults
        self.base = base
        self.protectedData = protectedData
        self.deviceName = deviceName
        identity = IdentityManager(defaultsSuite: nil, supportBase: base,
                                   protectedDataAvailable: { protectedData.read() })
    }

    func savedPCs() throws -> [SavedPC] {
        guard protectedData.read() else { throw Failure.unavailable }
        guard let data = defaults.data(forKey: Self.savedKey) else { return [] }
        return try JSONDecoder().decode([SavedPC].self, from: data)
    }

    func lastConnectedPCID() -> String? {
        guard protectedData.read() else { return nil }
        return defaults.string(forKey: Self.lastConnectedKey)
    }

    func forget(_ id: String) throws -> [SavedPC] {
        let remaining = try savedPCs().filter { $0.id != id }
        let encoded = try JSONEncoder().encode(remaining)
        // Keep the PC listed if its trust cannot be removed, so recovery can be retried.
        try PinnedCertStore.delete(forHostID: id, defaults: defaults, base: base,
                                   protectedDataAvailable: { protectedData.read() })
        defaults.set(encoded, forKey: Self.savedKey)
        if defaults.string(forKey: Self.lastConnectedKey) == id {
            defaults.removeObject(forKey: Self.lastConnectedKey)
        }
        return remaining
    }

    func prepare(server: ServerInfo, saved: Bool) async throws -> PreparedPC {
        guard protectedData.read() else { throw Failure.unavailable }
        var server = server
        if !server.uniqueId.isEmpty { server.serverCertPEM = try loadPin(server.uniqueId) }
        if saved && server.serverCertPEM == nil { throw Failure.missingPin }
        var network = makeNetwork(server)
        var fetched = try await network.fetchServerInfo(
            requiredUniqueId: server.serverCertPEM == nil ? nil : server.uniqueId)
        try Task.checkCancellation()
        guard !fetched.uniqueId.isEmpty else { throw Failure.invalidIdentity }
        if server.serverCertPEM == nil, let pin = try loadPin(fetched.uniqueId) {
            fetched.serverCertPEM = pin
            network = makeNetwork(fetched)
            fetched = try await network.fetchServerInfo(requiredUniqueId: fetched.uniqueId)
        }
        try Task.checkCancellation()
        guard protectedData.read() else { throw Failure.unavailable }
        return PreparedPC(network: network, server: fetched)
    }

    func pair(_ pc: PreparedPC, pin: String) async throws -> PreparedPC {
        guard protectedData.read() else { throw Failure.unavailable }
        // A failed pinned connection never authorizes replacement by a fresh pairing.
        guard try loadPin(pc.server.uniqueId) == nil else { throw Failure.missingPin }
        let paired = try await PairingClient(network: pc.network, server: pc.server)
            .pair(pin: pin, expectedUniqueId: pc.server.uniqueId)
        try Task.checkCancellation()
        guard paired.pairStatus == .paired, let pem = paired.serverCertPEM else { throw Failure.invalidIdentity }
        guard try loadPin(paired.uniqueId) == nil else { throw Failure.missingPin }
        try PinnedCertStore.store(pem: pem, forHostID: paired.uniqueId, defaults: defaults, base: base,
                                 protectedDataAvailable: { protectedData.read() })
        return PreparedPC(network: pc.network, server: paired)
    }

    func remember(_ pc: PreparedPC) throws -> [SavedPC] {
        guard pc.server.pairStatus == .paired, try loadPin(pc.server.uniqueId) != nil else {
            throw Failure.missingPin
        }
        var saved = try savedPCs().filter { $0.id != pc.server.uniqueId }
        saved.append(SavedPC(server: pc.server))
        saved.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        defaults.set(try JSONEncoder().encode(saved), forKey: Self.savedKey)
        defaults.set(pc.server.uniqueId, forKey: Self.lastConnectedKey)
        return saved
    }

    private func loadPin(_ id: String) throws -> String? {
        try PinnedCertStore.load(forHostID: id, defaults: defaults, base: base,
                                protectedDataAvailable: { protectedData.read() })
    }

    private func makeNetwork(_ server: ServerInfo) -> NetworkClient {
        NetworkClient(server: server, identity: identity, deviceName: deviceName)
    }
}

enum LauncherFailureCopy {
    static func message(_ error: Error) -> String {
        if case LauncherServices.Failure.missingPin = error {
            return "Glimmer couldn't use its saved pairing. In Settings → PCs, forget the PC and pair again."
        }
        if error is IdentityStorageError || error is LauncherServices.Failure {
            return "Glimmer couldn't read or save its pairing with the PC. Unlock the device and try again."
        }
        guard let error = error as? StreamError else {
            return "Couldn't connect to the PC. Check Sunshine and local network access, then try again."
        }
        switch error {
        case .pairingRejected, .pairingFailed:
            return "Pairing failed. Check the PIN in Sunshine on the PC and try again."
        case .hostCertChanged:
            return "The PC's identity has changed. If you reset Sunshine, "
                + "forget the PC in Settings → PCs and pair again."
        case .sunshineNeedsRestart:
            return "Restart Sunshine on the PC, then try connecting again."
        case .gameStreamHost:
            return StreamFailureCopy.needsSunshineMessage("the PC")
        case .hostTimedOut, .hostUnreachable:
            return "Couldn't reach the PC. Check Sunshine and the network, then try again."
        default:
            return "Couldn't connect to the PC. Check Sunshine and pairing, then try again."
        }
    }
}
