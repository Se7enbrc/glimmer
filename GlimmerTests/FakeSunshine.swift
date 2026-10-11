// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  FakeSunshine.swift
//
//  A Sunshine control endpoint behind NetworkClient's transport seam: it records every request and
//  answers through a handler, so request building and reply handling run without a socket.
//

import Foundation
import os
@testable import Glimmer

/// One control request as the fake PC received it.
struct FakeSunshineRequest: Sendable {
    let host: String
    let port: Int
    let target: String
    let userAgent: String
    let tls: Bool
    let credential: ControlTransport.TLSCredential
    let timeout: TimeInterval

    var path: String { URLComponents(string: target)?.path ?? "" }

    /// Decoded query values; the last one wins for a repeated name.
    var query: [String: String] {
        let items = URLComponents(string: target)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
    }
}

final class FakeSunshine: Sendable {
    typealias Handler = @Sendable (FakeSunshineRequest) throws -> ControlTransport.Response

    private let log = OSAllocatedUnfairLock<[FakeSunshineRequest]>(initialState: [])
    private let handler: Handler

    init(_ handler: @escaping Handler) { self.handler = handler }

    var requests: [FakeSunshineRequest] { log.withLock { $0 } }

    var transport: ControlTransport.Get {
        { [self] host, port, target, userAgent, tls, credential, timeout in
            let request = FakeSunshineRequest(host: host, port: port, target: target, userAgent: userAgent,
                                              tls: tls, credential: credential, timeout: timeout)
            log.withLock { $0.append(request) }
            return try handler(request)
        }
    }

    /// A NetworkClient that talks only to this fake and carries `identity` instead of the install's.
    func client(_ server: ServerInfo, identity: (certPEM: String, keyPEM: String)? = nil) -> NetworkClient {
        let cert = identity?.certPEM ?? "client-cert"
        let key = identity?.keyPEM ?? "client-key"
        return NetworkClient(server: server, transport: transport,
                             identity: { (cert, key, FakeSunshine.clientUniqueID) })
    }

    static let clientUniqueID = "C11E47C11E47C11E47C11E47C11E47C1"

    /// Answers each path (`"serverinfo"`, `"launch"`…) from its own script in order, repeating the
    /// last reply; an unscripted path fails, so a request the test didn't expect can't pass quietly.
    static func scripted(_ script: [String: [Result<ControlTransport.Response, StreamError>]]) -> FakeSunshine {
        let served = OSAllocatedUnfairLock<[String: Int]>(initialState: [:])
        return FakeSunshine { request in
            let path = String(request.path.dropFirst())
            guard let replies = script[path], let last = replies.last else {
                throw StreamError.launchFailed("unscripted \(path)")
            }
            let index = served.withLock { counts in
                defer { counts[path, default: 0] += 1 }
                return counts[path, default: 0]
            }
            return try (index < replies.count ? replies[index] : last).get()
        }
    }

    /// The paths requested so far, in order, without the leading slash.
    var paths: [String] { requests.map { String($0.path.dropFirst()) } }

    /// A 200 reply whose body is `<root status_code=…>` around `body`.
    static func xml(_ body: String, status: Int = 200) -> ControlTransport.Response {
        ControlTransport.Response(status: 200, body: Data("<root status_code=\"\(status)\">\(body)</root>".utf8))
    }

    static func server(pin: String? = nil) -> ServerInfo {
        var server = ServerInfo(address: "192.0.2.10", uniqueId: "tower-id", serverName: "Tower")
        server.serverCertPEM = pin
        return server
    }
}
