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

    /// The PEM material one control call carries: the client credential we
    /// present on the mutual-TLS handshake plus the host leaf we pin against.
    /// Grouped into one value so the request entry points stay inside the
    /// parameter-count bar; the fields keep their individual meanings verbatim.
    /// All-nil is the plain-HTTP unpaired probe (no cert, no pin).
    struct TLSCredential: Sendable {
        let clientCertPEM: String?
        let clientKeyPEM: String?
        /// non-nil → the host leaf must match it byte-for-byte (DER) or the
        /// handshake is refused (MITM gate). nil → first-contact pairing: any
        /// cert is accepted and returned for the caller to pin after RSA verifies.
        let pinnedCertPEM: String?
    }

    private static let log = Logger(subsystem: "io.ugfugl.Glimmer", category: "Stream.Network.TLS")
    private static let ioQueue = DispatchQueue(label: "io.ugfugl.Glimmer.control", attributes: .concurrent)

    /// Perform one HTTP/1.1 GET. `tls == false` is plain HTTP (the unpaired probe
    /// path - no cert, no pin); `tls == true` presents the client cert and pins.
    /// - credential: the client cert/key + pinned host leaf (see `TLSCredential`).
    static func get(host: String, port: Int, target: String,
                    userAgent: String,
                    tls: Bool,
                    credential: TLSCredential,
                    timeout: TimeInterval) async throws -> Response {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Response, Error>) in
            ioQueue.async {
                // OPENSSL PER-THREAD STATE RELEASE (the 2026-08-21 crash).
                // `ioQueue` is a concurrent dispatch queue, so this block runs on
                // POOLED GCD worker threads that the system retires when idle.
                // libcrypto plants thread-local state (ERR stacks, the 3.x
                // "master key" sparse array) on whatever thread runs a TLS
                // handshake, and reclaims it in a pthread TSD DESTRUCTOR at
                // thread exit. A 3-day process accumulated that state across
                // dozens of workers; when GCD retired one ~15min after a wake,
                // the destructor walked a days-old sparse array and crashed on
                // freed memory (sa_doall → ossl_sa_free → clean_master_key,
                // SIGSEGV at a 0x8080... poison address). OPENSSL_thread_stop is
                // the API the OpenSSL docs REQUIRE of threads the library didn't
                // create: it releases the per-thread state deterministically,
                // HERE, microseconds after it was planted and while it is
                // certainly valid - so thread retirement finds nothing to
                // reclaim. Cost: per-call state re-creation, trivial next to the
                // TLS handshake this block just performed. (The RTP/control
                // paths run on OWNED long-lived threads and the audio decrypt
                // path is plaintext for our hosts, so this transport is the one
                // pooled-thread OpenSSL user; the Swift-concurrency cooperative
                // pool's threads persist for the process lifetime.)
                defer { OPENSSL_thread_stop() }
                do {
                    cont.resume(returning: try performBlocking(
                        host: host, port: port, target: target, userAgent: userAgent,
                        tls: tls, credential: credential, timeout: timeout))
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
                                        credential: TLSCredential,
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

        if let certPEM = credential.clientCertPEM, let keyPEM = credential.clientKeyPEM {
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
        if let pinPEM = credential.pinnedCertPEM {
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
            // A nil base address means an EMPTY buffer, and the loop below would
            // not run for one anyway (sent == bytes.count == 0) - so bailing out
            // here is the same "nothing to write" outcome, without the trap.
            guard let base = raw.baseAddress else { return }
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

    /// Read until peer close or `Content-Length` body bytes arrive (SO_RCVTIMEO
    /// bounds a stuck read). A non-positive read mid-body surfaces as a distinct
    /// truncatedRead, not a half-body the XML parser later calls "Malformed XML".
    private static func readAll(fd: Int32, ssl: OpaquePointer?) throws -> Data {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 16 * 1024)
        var contentLength: Int?
        var headerEnd: Int?
        func bodyShort() -> Bool {
            guard let headerEnd, let contentLength else { return false }
            return data.count - headerEnd < contentLength
        }
        readLoop: while true {
            let n: Int = buf.withUnsafeMutableBytes { raw in
                if let ssl { return Int(SSL_read(ssl, raw.baseAddress, Int32(raw.count))) }
                return read(fd, raw.baseAddress, raw.count)
            }
            if n <= 0 {
                if let ssl {
                    switch SSL_get_error(ssl, Int32(n)) {
                    case SSL_ERROR_ZERO_RETURN:
                        break readLoop   // clean TLS close-notify EOF
                    case SSL_ERROR_WANT_READ, SSL_ERROR_WANT_WRITE:
                        // A blocking socket with SO_RCVTIMEO surfaces a recv-timeout
                        // as WANT_READ; retrying here would spin forever on a silent
                        // host. Body short of Content-Length = truncated; fail fast.
                        if bodyShort() {
                            throw StreamError.truncatedRead(
                                "TLS recv timed out mid-body (have \(data.count) bytes)")
                        }
                        break readLoop
                    default:
                        if bodyShort() {
                            throw StreamError.truncatedRead(
                                "TLS read failed mid-body (have \(data.count) bytes)")
                        }
                        break readLoop   // error after a complete/headerless body
                    }
                } else {
                    if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
                        if bodyShort() {
                            throw StreamError.truncatedRead(
                                "recv timed out mid-body (have \(data.count) bytes)")
                        }
                    }
                    break readLoop       // plaintext EOF (0) or non-retriable error
                }
            }
            data.append(contentsOf: buf[0..<n])

            // Once headers are complete, learn Content-Length so we can stop
            // exactly at the body end instead of waiting on the close.
            if headerEnd == nil, let r = data.range(of: Data("\r\n\r\n".utf8)) {
                headerEnd = r.upperBound
                contentLength = try contentLengthHeader(in: data[data.startIndex..<r.lowerBound])
            }
            if let headerEnd, let contentLength, data.count - headerEnd >= contentLength { break }
        }
        // A peer close before a declared Content-Length was met is a truncated body.
        if bodyShort() {
            throw StreamError.truncatedRead(
                "connection closed before Content-Length satisfied "
                + "(have \(data.count) bytes)")
        }
        return data
    }

    /// Read `Content-Length` out of a completed header block (the bytes BEFORE
    /// the blank-line terminator), so `readAll` can stop exactly at the body end
    /// instead of waiting on the peer close. nil = no usable header. Split out of
    /// `readAll` so the read loop stays inside the complexity bar; the last
    /// matching header line wins, exactly as the inline loop did.
    ///
    /// FAIL CLOSED on non-UTF-8 header bytes. HTTP/1.1 headers are protocol text;
    /// a lossy decode would silently substitute replacement characters and let us
    /// keep reading a stream we cannot actually parse. This is host-supplied
    /// input, so garbage in must surface as an error, not as a half-understood
    /// header.
    private static func contentLengthHeader(in headerBytes: Data) throws -> Int? {
        guard let head = String(bytes: headerBytes, encoding: .utf8) else {
            throw StreamError.hostUnreachable("malformed HTTP response (headers are not UTF-8)")
        }
        var length: Int?
        for line in head.split(separator: "\r\n") where line.lowercased().hasPrefix("content-length:") {
            length = Int(line.split(separator: ":")[1].trimmingCharacters(in: .whitespaces))
        }
        return length
    }

    // MARK: - HTTP/1.1 response parse

    private static func parse(_ raw: Data) throws -> Response {
        guard let sep = raw.range(of: Data("\r\n\r\n".utf8)) else {
            throw StreamError.hostUnreachable("malformed HTTP response (no header terminator)")
        }
        // Same fail-closed rule as `readAll`: header bytes that are not UTF-8 are
        // malformed protocol text, handled by the malformed-response path rather
        // than lossily decoded into a status line we only think we understood.
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
