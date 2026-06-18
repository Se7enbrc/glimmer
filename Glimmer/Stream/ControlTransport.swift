//
//  ControlTransport.swift
//
//  Mutual-TLS HTTP/1.1 client for the GameStream control channel, built directly
//  on the embedded OpenSSL (libssl) + POSIX sockets - NO URLSession, and crucially
//  NO keychain. The client cert + key load straight from PEM in memory
//  (SSL_CTX_use_certificate / _PrivateKey); the self-signed host cert is validated
//  by exact-DER pinning (X509_cmp) in place of CA validation - the same posture
//  the old URLSession TLSDelegate enforced. macOS only ever forced a
//  SecIdentity/login-keychain on us to satisfy URLSession; running TLS ourselves
//  removes it (and the sleep-lock class of bug) entirely.
//

import Foundation
import os.log

enum ControlTransport {

    /// One control response. `peerCertPEM` is the host's leaf cert (PEM) seen on
    /// the TLS handshake - returned on every paired call so the caller can pin it
    /// after the out-of-band RSA pairing handshake.
    struct Response: Sendable {
        let status: Int
        let body: Data
    }

    private static let log = Logger(subsystem: "io.ugfugl.Glimmer", category: "Stream.Network.TLS")
    private static let ioQueue = DispatchQueue(label: "io.ugfugl.Glimmer.control", attributes: .concurrent)

    /// Perform one HTTP/1.1 GET. `tls == false` is plain HTTP (the unpaired probe
    /// path - no cert, no pin); `tls == true` presents the client cert and pins.
    /// - pinnedCertPEM: non-nil → the host leaf must match it byte-for-byte (DER)
    ///   or the handshake is refused (MITM gate). nil → first-contact pairing: any
    ///   cert is accepted and returned for the caller to pin after RSA verifies.
    static func get(host: String, port: Int, target: String,
                    userAgent: String,
                    tls: Bool,
                    clientCertPEM: String?, clientKeyPEM: String?,
                    pinnedCertPEM: String?,
                    timeout: TimeInterval) async throws -> Response {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Response, Error>) in
            ioQueue.async {
                do {
                    cont.resume(returning: try performBlocking(
                        host: host, port: port, target: target, userAgent: userAgent,
                        tls: tls, clientCertPEM: clientCertPEM, clientKeyPEM: clientKeyPEM,
                        pinnedCertPEM: pinnedCertPEM, timeout: timeout))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Blocking worker (runs off-actor on ioQueue)

    private static func performBlocking(host: String, port: Int, target: String,
                                        userAgent: String,
                                        tls: Bool,
                                        clientCertPEM: String?, clientKeyPEM: String?,
                                        pinnedCertPEM: String?,
                                        timeout: TimeInterval) throws -> Response {
        let timeoutMs = Int32(max(1, timeout) * 1000)
        let fd = gl_tcp_connect(host, String(port), timeoutMs)
        guard fd >= 0 else {
            throw StreamError.hostUnreachable("connect to \(host):\(port) failed or timed out")
        }
        defer { close(fd) }

        // Build the request bytes once - same for the TLS and plaintext paths.
        var request = "GET \(target) HTTP/1.1\r\n"
        request += "Host: \(host):\(port)\r\n"
        request += "User-Agent: \(userAgent)\r\n"
        request += "Accept: */*\r\n"
        request += "Connection: close\r\n\r\n"
        let requestBytes = Array(request.utf8)

        if !tls {
            try writeAll(fd: fd, ssl: nil, requestBytes)
            let raw = try readAll(fd: fd, ssl: nil)
            return try parse(raw)
        }

        // --- TLS ----------------------------------------------------------
        guard let method = TLS_client_method(),
              let ctx = SSL_CTX_new(method) else {
            throw StreamError.crypto("SSL_CTX_new failed")
        }
        defer { SSL_CTX_free(ctx) }
        // Floor the handshake at TLS 1.2 - the pin is the real guarantee, this just
        // keeps us off legacy protocol versions. (Sunshine speaks 1.2/1.3.)
        _ = gl_ssl_ctx_set_min_tls12(ctx)
        // We pin instead of CA-validating (the host cert is self-signed); do the
        // pin check by hand after the handshake. VERIFY_NONE keeps SSL_connect
        // from rejecting the self-signed leaf before we get to look at it.
        SSL_CTX_set_verify(ctx, SSL_VERIFY_NONE, nil)

        if let certPEM = clientCertPEM, let keyPEM = clientKeyPEM {
            try loadClientCredential(ctx: ctx, certPEM: certPEM, keyPEM: keyPEM)
        }

        guard let ssl = SSL_new(ctx) else { throw StreamError.crypto("SSL_new failed") }
        defer { SSL_free(ssl) }
        SSL_set_fd(ssl, fd)
        guard SSL_connect(ssl) == 1 else {
            throw StreamError.hostUnreachable("TLS handshake to \(host):\(port) failed (SSL_connect)")
        }

        // Pinning + leaf capture.
        guard let peer = SSL_get1_peer_certificate(ssl) else {
            throw StreamError.hostUnreachable("host presented no certificate")
        }
        defer { X509_free(peer) }
        if let pinPEM = pinnedCertPEM {
            guard let pinned = x509(fromPEM: pinPEM) else {
                throw StreamError.crypto("could not parse pinned host cert")
            }
            defer { X509_free(pinned) }
            guard X509_cmp(peer, pinned) == 0 else {
                log.error("pinned host cert mismatch - refusing (possible MITM or host re-imaged)")
                throw StreamError.hostUnreachable("pinned host cert mismatch")
            }
        }

        try writeAll(fd: fd, ssl: ssl, requestBytes)
        let raw = try readAll(fd: fd, ssl: ssl)
        SSL_shutdown(ssl)   // best-effort clean close; body is already read
        return try parse(raw)
    }

    // MARK: - Client credential (PEM → SSL_CTX, no keychain)

    private static func loadClientCredential(ctx: OpaquePointer, certPEM: String, keyPEM: String) throws {
        guard let cert = x509(fromPEM: certPEM) else {
            throw StreamError.crypto("could not parse client cert PEM")
        }
        defer { X509_free(cert) }
        guard SSL_CTX_use_certificate(ctx, cert) == 1 else {
            throw StreamError.crypto("SSL_CTX_use_certificate failed")
        }
        guard let key = pkey(fromPEM: keyPEM) else {
            throw StreamError.crypto("could not parse client key PEM")
        }
        defer { EVP_PKEY_free(key) }
        guard SSL_CTX_use_PrivateKey(ctx, key) == 1 else {
            throw StreamError.crypto("SSL_CTX_use_PrivateKey failed")
        }
        guard SSL_CTX_check_private_key(ctx) == 1 else {
            throw StreamError.crypto("client cert/key mismatch")
        }
    }

    // MARK: - PEM <-> OpenSSL helpers

    private static func x509(fromPEM pem: String) -> OpaquePointer? {
        Array(pem.utf8).withUnsafeBytes { raw -> OpaquePointer? in
            guard let bio = BIO_new_mem_buf(raw.baseAddress, Int32(raw.count)) else { return nil }
            defer { BIO_free(bio) }
            return PEM_read_bio_X509(bio, nil, nil, nil)
        }
    }

    private static func pkey(fromPEM pem: String) -> OpaquePointer? {
        Array(pem.utf8).withUnsafeBytes { raw -> OpaquePointer? in
            guard let bio = BIO_new_mem_buf(raw.baseAddress, Int32(raw.count)) else { return nil }
            defer { BIO_free(bio) }
            return PEM_read_bio_PrivateKey(bio, nil, nil, nil)
        }
    }

    // MARK: - Socket / TLS IO

    private static func writeAll(fd: Int32, ssl: OpaquePointer?, _ bytes: [UInt8]) throws {
        var sent = 0
        try bytes.withUnsafeBytes { raw in
            let base = raw.baseAddress!
            while sent < bytes.count {
                let n: Int
                if let ssl {
                    n = Int(SSL_write(ssl, base + sent, Int32(bytes.count - sent)))
                } else {
                    n = write(fd, base + sent, bytes.count - sent)
                }
                guard n > 0 else { throw StreamError.hostUnreachable("control write failed") }
                sent += n
            }
        }
    }

    /// Read until the peer closes (we send `Connection: close`) or `Content-Length`
    /// bytes of body have arrived. The socket's SO_RCVTIMEO bounds a stuck read.
    private static func readAll(fd: Int32, ssl: OpaquePointer?) throws -> Data {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 16 * 1024)
        var contentLength: Int?
        var headerEnd: Int?
        while true {
            let n: Int = buf.withUnsafeMutableBytes { raw in
                if let ssl { return Int(SSL_read(ssl, raw.baseAddress, Int32(raw.count))) }
                return read(fd, raw.baseAddress, raw.count)
            }
            if n <= 0 { break }   // clean close, EOF, or recv timeout
            data.append(contentsOf: buf[0..<n])

            // Once headers are complete, learn Content-Length so we can stop
            // exactly at the body end instead of waiting on the close.
            if headerEnd == nil, let r = data.range(of: Data("\r\n\r\n".utf8)) {
                headerEnd = r.upperBound
                let head = String(decoding: data[data.startIndex..<r.lowerBound], as: UTF8.self)
                for line in head.split(separator: "\r\n") where line.lowercased().hasPrefix("content-length:") {
                    contentLength = Int(line.split(separator: ":")[1].trimmingCharacters(in: .whitespaces))
                }
            }
            if let headerEnd, let contentLength, data.count - headerEnd >= contentLength { break }
        }
        return data
    }

    // MARK: - HTTP/1.1 response parse

    private static func parse(_ raw: Data) throws -> Response {
        guard let sep = raw.range(of: Data("\r\n\r\n".utf8)) else {
            throw StreamError.hostUnreachable("malformed HTTP response (no header terminator)")
        }
        let head = String(decoding: raw[raw.startIndex..<sep.lowerBound], as: UTF8.self)
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
