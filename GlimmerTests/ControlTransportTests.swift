//
//  ControlTransportTests.swift
//
//  The control channel's mutual TLS without a PC: a loopback listener plays Sunshine, requiring this
//  Mac's certificate, so the in-memory identity and the exact-DER pin run end to end.
//

import Foundation
import Network
import Testing
@testable import Glimmer

@Suite struct ControlTransportTests {

    @Test func identityLoadsFromItsPEMFiles() async throws {
        let (certPEM, keyPEM) = try await IdentityManager.shared.generateKeyPairAndCert()
        _ = try ControlTransport.clientIdentity(certPEM: certPEM, keyPEM: keyPEM)
    }

    @Test func identityRefusesAKeyFromAnotherCert() async throws {
        let (certA, _) = try await IdentityManager.shared.generateKeyPairAndCert()
        let (_, keyB) = try await IdentityManager.shared.generateKeyPairAndCert()
        #expect(throws: StreamError.self) { try ControlTransport.clientIdentity(certPEM: certA, keyPEM: keyB) }
    }

    @Test func pinnedPCAnswersThisMac() async throws {
        let pc = try await IdentityManager.shared.generateKeyPairAndCert()
        let mac = try await IdentityManager.shared.generateKeyPairAndCert()
        let server = try await LoopbackSunshine.start(presenting: pc, accepting: mac.certPEM)
        defer { server.cancel() }
        let response = try await Self.pairedGet(port: server.port, mac: mac, pin: pc.certPEM)
        #expect(response.status == 200)
        #expect(response.body == Data("ok".utf8))
    }

    @Test func pcWithAnotherCertIsRefused() async throws {
        let pc = try await IdentityManager.shared.generateKeyPairAndCert()
        let impostor = try await IdentityManager.shared.generateKeyPairAndCert()
        let mac = try await IdentityManager.shared.generateKeyPairAndCert()
        let server = try await LoopbackSunshine.start(presenting: impostor, accepting: mac.certPEM)
        defer { server.cancel() }
        do {
            _ = try await Self.pairedGet(port: server.port, mac: mac, pin: pc.certPEM)
            Issue.record("A PC presenting another certificate was accepted")
        } catch StreamError.hostUnreachable(let detail) {
            #expect(detail == "pinned host cert mismatch")
        }
    }

    private static func pairedGet(port: Int, mac: (certPEM: String, keyPEM: String),
                                  pin: String) async throws -> ControlTransport.Response {
        try await ControlTransport.get(
            host: "127.0.0.1", port: port, target: "/serverinfo", userAgent: "GlimmerTests", tls: true,
            credential: .init(clientCertPEM: mac.certPEM, clientKeyPEM: mac.keyPEM, pinnedCertPEM: pin),
            timeout: 5)
    }
}

/// A one-reply TLS server on loopback that, like Sunshine, only talks to the certificate it paired with.
private struct LoopbackSunshine {
    let listener: NWListener
    let port: Int

    static func start(presenting identity: (certPEM: String, keyPEM: String),
                      accepting clientCertPEM: String) async throws -> LoopbackSunshine {
        let queue = DispatchQueue(label: "io.ugfugl.Glimmer.tests.tls")
        let options = NWProtocolTLS.Options()
        let security = options.securityProtocolOptions
        sec_protocol_options_set_local_identity(
            security, try ControlTransport.clientIdentity(certPEM: identity.certPEM, keyPEM: identity.keyPEM))
        sec_protocol_options_set_peer_authentication_required(security, true)
        let expected = ControlTransport.derBytes(fromPEM: clientCertPEM)
        sec_protocol_options_set_verify_block(security, { _, trust, complete in
            let chain = SecTrustCopyCertificateChain(sec_trust_copy_ref(trust).takeRetainedValue())
            let leaf = (chain as? [SecCertificate])?.first
            complete(leaf.map { SecCertificateCopyData($0) as Data == expected } ?? false)
        }, queue)
        let listener = try NWListener(using: NWParameters(tls: options), on: .any)
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, _ in
                connection.send(content: Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok".utf8),
                                completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        let port = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        return LoopbackSunshine(listener: listener, port: Int(port))
    }

    func cancel() { listener.cancel() }
}
