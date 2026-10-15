// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import GlimmerEngine

extension NetworkClient {
    static let installIdentity: Identity = {
        let identity = IdentityManager.shared
        return (try await identity.clientCertPEM(), try await identity.clientKeyPEM(), try await identity.uniqueID())
    }

    init(server: ServerInfo, transport: @escaping ControlTransport.Get = ControlTransport.get,
         identity: @escaping Identity = NetworkClient.installIdentity,
         deviceName: @escaping @Sendable () -> String = { NetworkClient.pairingDeviceName }) {
        self.init(server: server, deviceName: deviceName, transport: transport, identity: identity)
    }

    /// What the host's pairing page shows for this Mac: its computer name, or
    /// "Glimmer" when that is unavailable. Replaces Moonlight's legacy "roth".
    static var pairingDeviceName: String {
        let name = Foundation.Host.current().localizedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "Glimmer" : name
    }

    func launch(appID: Int, config: StreamConfig) async throws -> LaunchResponse {
        try await launch(appID: appID, config: config.request)
    }

    func resume(config: StreamConfig) async throws -> LaunchResponse {
        try await resume(config: config.request)
    }

    static func launchQuery(config: StreamConfig, riKeyHex: String, riKeyID: Int32, appID: Int?) -> [String: String] {
        launchQuery(config: config.request, riKeyHex: riKeyHex, riKeyID: riKeyID, appID: appID)
    }
}
