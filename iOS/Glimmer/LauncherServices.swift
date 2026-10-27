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

    init(defaults: UserDefaults = PersistentStorage.defaults, base: URL, protectedData: ProtectedDataState,
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
        TouchLayoutStore(defaults: defaults).forget(pcID: id)
        if defaults.string(forKey: Self.lastConnectedKey) == id {
            defaults.removeObject(forKey: Self.lastConnectedKey)
        }
        return remaining
    }

    func prepare(server: ServerInfo, saved: Bool) async throws -> PreparedPC {
        try await Self.prepareRecovering(server: server, saved: saved, prepare: prepareOnce, recover: recoverAddress)
    }

    static func prepareRecovering(server: ServerInfo, saved: Bool,
                                  prepare: (ServerInfo, Bool) async throws -> PreparedPC,
                                  recover: (ServerInfo) async throws -> ServerInfo?) async throws -> PreparedPC {
        do { return try await prepare(server, saved) } catch {
            try Task.checkCancellation()
            guard saved, HostAddressRecovery.canHeal(server.address),
                  let failure = error as? StreamError else { throw error }
            switch failure {
            case .hostUnreachable, .hostTimedOut: break
            default: throw error
            }
            guard let moved = try await recover(server), moved.uniqueId == server.uniqueId,
                  moved.serverCertPEM != nil else { throw error }
            try Task.checkCancellation()
            return try await prepare(moved, true)
        }
    }

    private func recoverAddress(_ server: ServerInfo) async throws -> ServerInfo? {
        guard protectedData.read() else { throw Failure.unavailable }
        var pinned = server
        pinned.serverCertPEM = try loadPin(server.uniqueId)
        let identity = identity
        let deviceName = deviceName
        guard let moved = await HostAddressRecovery.find(pinned, makeNetwork: {
            NetworkClient(server: $0, identity: identity, deviceName: deviceName)
        }) else { return nil }
        let status = await HostReachability.measureRTT(host: server.address, port: server.httpPort, timeoutMs: 2_000)
        try Task.checkCancellation()
        guard protectedData.read() else { throw Failure.unavailable }
        return status == .unreachable ? moved : nil
    }

    private func prepareOnce(server: ServerInfo, saved: Bool) async throws -> PreparedPC {
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

    func pair(_ pc: PreparedPC, pin: String,
              authenticate: @MainActor (PreparedPC, String) async throws -> ServerInfo = { pc, pin in
                  try await PairingClient(network: pc.network, server: pc.server)
                      .pair(pin: pin, expectedUniqueId: pc.server.uniqueId)
              }) async throws -> PreparedPC {
        guard protectedData.read() else { throw Failure.unavailable }
        // A failed pinned connection never authorizes replacement by a fresh pairing.
        guard try loadPin(pc.server.uniqueId) == nil else { throw Failure.missingPin }
        let paired = try await authenticate(pc, pin)
        try Task.checkCancellation()
        guard paired.pairStatus == .paired, let pem = paired.serverCertPEM else { throw Failure.invalidIdentity }
        guard try loadPin(paired.uniqueId) == nil else { throw Failure.missingPin }
        // Recovery must be available even if the app list or pin write fails afterward.
        _ = try savePC(paired)
        try PinnedCertStore.store(pem: pem, forHostID: paired.uniqueId, defaults: defaults, base: base,
                                 protectedDataAvailable: { protectedData.read() })
        return PreparedPC(network: pc.network, server: paired)
    }

    func remember(_ pc: PreparedPC) throws -> [SavedPC] {
        guard pc.server.pairStatus == .paired, try loadPin(pc.server.uniqueId) != nil else {
            throw Failure.missingPin
        }
        let saved = try savePC(pc.server)
        defaults.set(pc.server.uniqueId, forKey: Self.lastConnectedKey)
        return saved
    }

    private func savePC(_ server: ServerInfo) throws -> [SavedPC] {
        var saved = try savedPCs().filter { $0.id != server.uniqueId }
        saved.append(SavedPC(server: server))
        saved.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        defaults.set(try JSONEncoder().encode(saved), forKey: Self.savedKey)
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
    private static func isProtectedDataUnavailable(_ error: Error) -> Bool {
        if case IdentityStorageError.unavailable = error { return true }
        if case LauncherServices.Failure.unavailable = error { return true }
        return false
    }

    static func storageMessage(_ error: Error, action: String) -> String {
        let recovery = isProtectedDataUnavailable(error) ? "Unlock the device and try again."
            : "Close the app and try again."
        return "Glimmer couldn't \(action). \(recovery)"
    }

    static func message(_ error: Error, pcName: String = "the PC") -> String {
        if StreamFailure.connection(error) == .identityNeedsRestore {
            return StreamFailureCopy.identityNeedsRestore(pcName)
        }
        if case LauncherServices.Failure.missingPin = error {
            return "Glimmer couldn't use its saved pairing with \(pcName). "
                + "In Settings → PCs, forget the PC and pair again."
        }
        if isProtectedDataUnavailable(error) {
            return storageMessage(error, action: "read or save its pairing with \(pcName)")
        }
        if case IdentityStorageError.defaultsUnavailable = error {
            return storageMessage(error, action: "open its storage")
        }
        guard let error = error as? StreamError else {
            return "Couldn't connect to \(pcName). Check Sunshine and local network access, then try again."
        }
        switch error {
        case .pairingRejected, .pairingFailed:
            return "Pairing with \(pcName) failed. Check the PIN in Sunshine on the PC and try again."
        case .hostCertChanged:
            return "The identity of \(pcName) has changed. If you reset Sunshine, "
                + "forget the PC in Settings → PCs and pair again."
        case .sunshineNeedsRestart:
            return "Restart Sunshine on \(pcName), then try connecting again."
        case .gameStreamHost:
            return StreamFailureCopy.needsSunshineMessage(pcName)
        case .hostTimedOut, .hostUnreachable:
            return "Couldn't reach \(pcName). Check Sunshine and the network, then try again."
        default:
            return "Couldn't connect to \(pcName). Check Sunshine and pairing, then try again."
        }
    }
}
