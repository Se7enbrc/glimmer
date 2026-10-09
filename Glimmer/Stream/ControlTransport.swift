//
//  ControlTransport.swift
//
//  HTTP/1.1 client for the control channel on Network.framework: mutual TLS with an in-memory
//  client identity and the PC's self-signed cert pinned by exact DER, so neither the keychain
//  nor CA trust is ever in the path.
//

import Foundation
import Network
import Security
import os

enum ControlTransport {

    final class RequestLifetime: Sendable {
        let deadline: Date
        private struct State {
            var cancelled = false
            var connection: NWConnection?
        }
        private let state = OSAllocatedUnfairLock(initialState: State())

        init(timeout: TimeInterval) { deadline = Date().addingTimeInterval(timeout) }

        /// Cancel the attached connection so a pending handshake or read ends now.
        func cancel() {
            let connection = state.withLock { state -> NWConnection? in
                state.cancelled = true
                return state.connection
            }
            connection?.cancel()
        }

        /// False when the request was cancelled before its connection existed; it never starts.
        func attach(_ connection: NWConnection) -> Bool {
            state.withLock { state in
                guard !state.cancelled else { return false }
                state.connection = connection
                return true
            }
        }

        var isCancelled: Bool { state.withLock { $0.cancelled } }
    }

    /// One control response.
    struct Response: Sendable {
        let status: Int
        let body: Data
    }

    /// The PEM material one control call carries: the client credential we
    /// present on the mutual-TLS handshake plus the host leaf we pin against.
    /// All-nil is the plain-HTTP unpaired probe (no cert, no pin).
    struct TLSCredential: Sendable {
        let clientCertPEM: String?
        let clientKeyPEM: String?
        /// The host leaf must match it byte-for-byte (DER) or the handshake is
        /// refused (MITM gate). NetworkClient never opens TLS without one, and
        /// only a finished PIN handshake supplies it.
        let pinnedCertPEM: String?
    }

    private static let log = Logger(subsystem: "io.ugfugl.Glimmer", category: "Stream.Network.TLS")

    /// Requests wrapped in `StreamAttempt.run` report its deadline as `hostTimedOut`; this
    /// backstop only ends an unwrapped `/launch`, so it lands just after the same deadline.
    static let backstopGrace: TimeInterval = 0.25

    /// Perform one HTTP/1.1 GET. `tls == false` is plain HTTP (the unpaired probe
    /// path - no cert, no pin); `tls == true` presents the client cert and pins.
    static func get(host: String, port: Int, target: String,
                    userAgent: String,
                    tls: Bool,
                    credential: TLSCredential,
                    timeout: TimeInterval) async throws -> Response {
        let lifetime = RequestLifetime(timeout: timeout)
        var request = "GET \(target) HTTP/1.1\r\n"
        request += "Host: \(host):\(port)\r\n"
        request += "User-Agent: \(userAgent)\r\n"
        request += "Accept: */*\r\n"
        request += "Connection: close\r\n\r\n"
        let exchange = Exchange(host: host, port: port, request: Data(request.utf8), lifetime: lifetime)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard let rawPort = UInt16(exactly: port), rawPort > 0,
                  let endpointPort = NWEndpoint.Port(rawValue: rawPort) else {
                throw StreamError.hostUnreachable("invalid control port \(port)")
            }
            let parameters = try exchange.parameters(tls: tls, credential: credential)
            return try await exchange.run(NWConnection(host: NWEndpoint.Host(host), port: endpointPort,
                                                       using: parameters))
        } onCancel: {
            lifetime.cancel()
        }
    }

    // MARK: - One request

    /// One request's connection and reply. Invariant: `reply` and `continuation` are only
    /// touched on `queue`, which runs every connection callback, the backstop, and the start.
    private final class Exchange: @unchecked Sendable {
        let queue = DispatchQueue(label: "io.ugfugl.Glimmer.control", qos: .userInitiated)
        let host: String
        let port: Int
        let request: Data
        let lifetime: RequestLifetime
        /// Why the verify block refused the PC; written there, read when the handshake fails.
        private let pinRejection = OSAllocatedUnfairLock<String?>(initialState: nil)
        private var reply = ResponseBuffer()
        private var continuation: CheckedContinuation<Response, Error>?

        init(host: String, port: Int, request: Data, lifetime: RequestLifetime) {
            self.host = host
            self.port = port
            self.request = request
            self.lifetime = lifetime
        }

        func parameters(tls: Bool, credential: TLSCredential) throws -> NWParameters {
            guard tls else { return .tcp }
            let options = NWProtocolTLS.Options()
            let security = options.securityProtocolOptions
            // The pin is the guarantee; the floor just keeps the handshake off legacy versions.
            sec_protocol_options_set_min_tls_protocol_version(security, .TLSv12)
            // A resumed session skips the verify block, so every connection does a full handshake.
            sec_protocol_options_set_tls_resumption_enabled(security, false)
            if let certPEM = credential.clientCertPEM, let keyPEM = credential.clientKeyPEM {
                sec_protocol_options_set_local_identity(security, try clientIdentity(certPEM: certPEM, keyPEM: keyPEM))
            }
            let pinned = try credential.pinnedCertPEM.map { pem in
                _ = try PEM.certificateKey(pem, context: "paired PC certificate")
                guard let der = PEM.der(pem) else { throw StreamError.crypto("could not parse pinned host cert") }
                return der
            }
            let rejection = pinRejection
            // Self-signed, so pinned instead of CA-validated: the leaf must byte-equal the pin.
            sec_protocol_options_set_verify_block(security, { _, trust, complete in
                let chain = SecTrustCopyCertificateChain(sec_trust_copy_ref(trust).takeRetainedValue())
                guard let leaf = (chain as? [SecCertificate])?.first else {
                    rejection.withLock { $0 = "host presented no certificate" }
                    return complete(false)
                }
                let matches: Bool
                do {
                    matches = try acceptsHostCertificate(leaf, pinnedDER: pinned)
                } catch {
                    rejection.withLock { $0 = "PC certificate requires an RSA key of at least 2048 bits" }
                    return complete(false)
                }
                if !matches { rejection.withLock { $0 = "pinned host cert mismatch" } }
                complete(matches)
            }, queue)
            return NWParameters(tls: options)
        }

        func run(_ connection: NWConnection) async throws -> Response {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    self.continuation = continuation
                    guard lifetime.attach(connection) else { return finish(.failure(CancellationError()), closing: nil) }
                    connection.stateUpdateHandler = { [self] state in handle(state, on: connection) }
                    connection.start(queue: queue)
                    let backstop = max(0, lifetime.deadline.timeIntervalSinceNow) + backstopGrace
                    queue.asyncAfter(deadline: .now() + backstop) { [self] in
                        finish(.failure(StreamError.hostUnreachable("Control request timed out.")), closing: connection)
                    }
                }
            }
        }

        private func handle(_ state: NWConnection.State, on connection: NWConnection) {
            switch state {
            case .ready:
                connection.send(content: request, completion: .contentProcessed { [self] error in
                    if let error { return finish(.failure(failure(error)), closing: connection) }
                    receive(on: connection)
                })
            case .waiting(let error), .failed(let error):
                // Network.framework retries a waiting connection; a control request fails now instead.
                finish(.failure(failure(error)), closing: connection)
            case .cancelled:
                finish(.failure(StreamError.hostUnreachable("control connection closed")), closing: nil)
            default:
                break
            }
        }

        private func receive(on connection: NWConnection) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [self] data, _, isComplete, error in
                do {
                    if let data, try reply.append(data) {
                        return finish(.success(try parse(reply.bytes)), closing: connection)
                    }
                    // The PC's close ends the reply; a body short of Content-Length is truncated.
                    if isComplete || error != nil {
                        return finish(.success(try parse(reply.finish())), closing: connection)
                    }
                    receive(on: connection)
                } catch {
                    finish(.failure(error), closing: connection)
                }
            }
        }

        /// The error a connection failure reports, in the wording `classifyPairedPathFailure` reads.
        private func failure(_ error: NWError) -> Error {
            if let rejection = pinRejection.withLock({ $0 }) {
                log.error("\(rejection, privacy: .public) - refusing (possible MITM or host re-imaged)")
                return StreamError.hostUnreachable(rejection)
            }
            if case .tls = error {
                return StreamError.hostUnreachable("TLS handshake to \(host):\(port) failed (\(error))")
            }
            return StreamError.hostUnreachable("connect to \(host):\(port) failed or timed out")
        }

        /// Resumes the caller once; a cancelled request always reports cancellation.
        private func finish(_ result: Result<Response, Error>, closing connection: NWConnection?) {
            connection?.cancel()
            guard let continuation else { return }
            self.continuation = nil
            if case .failure = result, lifetime.isCancelled { return continuation.resume(throwing: CancellationError()) }
            continuation.resume(with: result)
        }
    }

    // MARK: - Client identity (PEM to an in-memory identity, no keychain)

    static func acceptsHostCertificate(_ certificate: SecCertificate, pinnedDER: Data?) throws -> Bool {
        _ = try PEM.certificateKey(certificate, context: "PC certificate")
        return pinnedDER.map { SecCertificateCopyData(certificate) as Data == $0 } ?? true
    }

    /// The client identity from its PEM files, held in memory only.
    static func clientIdentity(certPEM: String, keyPEM: String) throws -> sec_identity_t {
        let identity = try PEM.identity(certPEM: certPEM, keyPEM: keyPEM)
        guard let secIdentity = sec_identity_create(identity) else {
            throw StreamError.crypto("could not create TLS client identity")
        }
        return secIdentity
    }

    // MARK: - Reply

    /// Ceiling for one control response. Real replies are tens of KiB of XML at
    /// most, so anything past this is a broken or hostile responder.
    static let maxResponseBytes = 4 * 1024 * 1024

    /// One reply as it arrives: whole at `Content-Length` when the PC sends one, else at close.
    struct ResponseBuffer {
        private(set) var bytes = Data()
        private var headerEnd: Int?
        private var contentLength: Int?

        /// Adds a chunk; true once the body has reached `Content-Length`.
        mutating func append(_ chunk: Data) throws -> Bool {
            bytes.append(chunk)
            if headerEnd == nil, let separator = bytes.range(of: Data("\r\n\r\n".utf8)) {
                headerEnd = separator.upperBound
                contentLength = try contentLengthHeader(in: bytes[bytes.startIndex..<separator.lowerBound])
            }
            if bytes.count > maxResponseBytes || (contentLength ?? 0) > maxResponseBytes {
                throw StreamError.hostUnreachable("control response too large")
            }
            guard let headerEnd, let contentLength else { return false }
            return bytes.count - headerEnd >= contentLength
        }

        /// The reply once the PC closes; a body short of its `Content-Length` is a truncated read.
        func finish() throws -> Data {
            if let headerEnd, let contentLength, bytes.count - headerEnd < contentLength {
                throw StreamError.truncatedRead(
                    "connection closed before Content-Length satisfied (have \(bytes.count) bytes)")
            }
            return bytes
        }
    }

    /// `Content-Length` from a completed header block, so a reply ends at its body instead of
    /// the PC's close; the last matching line wins, and nil (also for an empty or negative value) = no header.
    /// Fails closed on non-UTF-8 headers: this is host-supplied input, and a lossy decode would half-parse it.
    static func contentLengthHeader(in headerBytes: Data) throws -> Int? {
        guard let head = String(bytes: headerBytes, encoding: .utf8) else {
            throw StreamError.hostUnreachable("malformed HTTP response (headers are not UTF-8)")
        }
        var length: Int?
        for line in head.split(separator: "\r\n") where line.lowercased().hasPrefix("content-length:") {
            let parts = line.split(separator: ":", maxSplits: 1)
            let value = parts.count == 2 ? Int(parts[1].trimmingCharacters(in: .whitespaces)) : nil
            length = value.flatMap { $0 >= 0 ? $0 : nil }
        }
        return length
    }

    // MARK: - HTTP/1.1 response parse

    private static func parse(_ raw: Data) throws -> Response {
        guard let sep = raw.range(of: Data("\r\n\r\n".utf8)) else {
            throw StreamError.hostUnreachable("malformed HTTP response (no header terminator)")
        }
        // Header bytes that are not UTF-8 are malformed protocol text, handled by the
        // malformed-response path rather than lossily decoded into a status line.
        guard let head = String(bytes: raw[raw.startIndex..<sep.lowerBound], encoding: .utf8) else {
            throw StreamError.hostUnreachable("malformed HTTP response (headers are not UTF-8)")
        }
        guard let statusLine = head.split(separator: "\r\n").first else {
            throw StreamError.hostUnreachable("empty HTTP response")
        }
        // "HTTP/1.1 200 OK" -> 200
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2, let status = Int(parts[1]) else {
            throw StreamError.hostUnreachable("unparseable HTTP status line: \(statusLine)")
        }
        let body = Data(raw[sep.upperBound...])
        return Response(status: status, body: body)
    }
}
