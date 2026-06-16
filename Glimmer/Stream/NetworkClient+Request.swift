//
//  NetworkClient+Request.swift
//
//  The low-level HTTPS request plumbing NetworkClient and Pairing share
//  (request/rawRequest/performRequest), response status verification, codec-mode
//  decoding, and the small request helpers (timeouts, nonce, secure random,
//  hex). Split out of Network.swift to keep each unit focused.
//

import Foundation
import Network
import os.log

extension NetworkClient {

    // MARK: - Low-level request (also used by Pairing.swift)

    /// Raw access used by Pairing.swift for the multi-step pairing handshake.
    /// `usePaired = true` means HTTPS (47984) with mutual TLS via client cert.
    /// `usePaired = false` means HTTP (47989).
    public func request(path: String,
                        query: [String: String],
                        usePaired: Bool,
                        timeout: TimeInterval = NetworkClient.controlTimeout) async throws -> XMLNode {
        try await rawRequest(path: path,
                             query: query,
                             extraQuery: nil,
                             usePaired: usePaired,
                             timeout: timeout)
    }

    /// Workhorse. Builds the URL, attaches our uniqueid + a per-request UUID
    /// (matches GFE's expectation that every request has a unique nonce),
    /// optionally appends an unescaped query tail (for the backend's launch
    /// params, which must NOT be URL-percent-encoded - they arrive already
    /// encoded).
    func rawRequest(path: String,
                    query: [String: String],
                    extraQuery: String?,
                    usePaired: Bool,
                    timeout: TimeInterval) async throws -> XMLNode {

        try await ensureIdentityLoaded()
        if usePaired { _ = try await ensureClientIdentity() }

        // IMPORTANT: GFE keys its per-session state on `uniqueid`. moonlight-qt
        // intentionally hard-codes "0123456789ABCDEF" so any moonlight client
        // can quit a game started by any other one (otherwise GFE wedges and
        // requires manual intervention to recover). The host's own UUID lives
        // on ServerInfo.uniqueId; that is NOT what goes on the wire here. We
        // still load the IdentityManager-generated client uniqueid in
        // ensureIdentityLoaded() because it's persisted for debugging /
        // forward-compat, but it must not be sent.
        let uid = Self.wireUniqueID
        let scheme = usePaired ? "https" : "http"
        let port = usePaired ? server.httpsPort : server.httpPort

        var components = URLComponents()
        components.scheme = scheme
        components.host = server.address
        components.port = port
        components.path = "/" + path

        var items: [URLQueryItem] = [
            URLQueryItem(name: "uniqueid", value: uid),
            URLQueryItem(name: "uuid", value: Self.requestNonce())
        ]
        for (key, value) in query.sorted(by: { $0.key < $1.key }) {
            items.append(URLQueryItem(name: key, value: value))
        }
        components.queryItems = items

        guard var url = components.url else {
            throw StreamError.hostUnreachable("Failed to build URL for /\(path)")
        }
        // Append the launch-params tail literally - it carries its own
        // pre-encoded form and percent-encoding it again would break it.
        if let extra = extraQuery, !extra.isEmpty {
            let trimmed = extra.hasPrefix("&") ? extra : "&" + extra
            if let appended = URL(string: url.absoluteString + trimmed) {
                url = appended
            }
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = timeout
        // Belt + braces against any cached "Hey, you connected to this host
        // five minutes ago, want to reuse?" behavior from URLSession.
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        // Match moonlight-qt's User-Agent so Sunshine's per-client capability
        // gating doesn't refuse HDR or other features on an unknown UA. Qt's
        // QNetworkAccessManager sends "Mozilla/5.0" by default; moonlight-qt
        // doesn't override it, so the wire UA reads as Qt's stock string.
        // Sunshine's HDR negotiation has at times refused unknown clients, so
        // we put on the same hat.
        req.setValue("Mozilla/5.0 (compatible; Moonlight/Glimmer)", forHTTPHeaderField: "User-Agent")

        // SECURITY: redact the URL before logging - query string may carry
        // rikey/rikeyid/uuid/uniqueid (session AES key + per-request nonce)
        // which must not appear in unified log even at .debug level.
        log.debug("GET \(Self.redactedURL(url), privacy: .public)")

        let (data, response) = try await performRequest(req)

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            // GameStream actually puts errors in the body XML and returns
            // HTTP 200, so this only fires for transport-level breakage like
            // a 401 from a misconfigured reverse proxy.
            throw StreamError.launchFailed("HTTP \(http.statusCode) on /\(path)")
        }

        do {
            return try XMLTreeBuilder.parse(data: data)
        } catch {
            throw StreamError.launchFailed("Malformed XML on /\(path): \(error)")
        }
    }

    /// Bridges URLSession's data-task API into async/await with a real timeout.
    /// We use `dataTask(with:completionHandler:)` rather than the async helper
    /// so the URLSession delegate's TLS challenge runs on the session's own
    /// queue - the async helper short-circuits some delegate callbacks on
    /// older macOS releases.
    func performRequest(_ req: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data, URLResponse), Error>) in
            let task = session.dataTask(with: req) { data, response, error in
                if let error {
                    let nserr = error as NSError
                    switch nserr.code {
                    case NSURLErrorTimedOut:
                        cont.resume(throwing: StreamError.hostUnreachable("Request timed out"))
                    case NSURLErrorServerCertificateUntrusted,
                         NSURLErrorClientCertificateRejected,
                         NSURLErrorClientCertificateRequired,
                         NSURLErrorSecureConnectionFailed:
                        cont.resume(throwing: StreamError.hostUnreachable("TLS handshake failed: \(nserr.localizedDescription)"))
                    default:
                        cont.resume(throwing: StreamError.hostUnreachable(nserr.localizedDescription))
                    }
                    return
                }
                guard let data, let response else {
                    cont.resume(throwing: StreamError.hostUnreachable("Empty response"))
                    return
                }
                cont.resume(returning: (data, response))
            }
            task.resume()
        }
    }

    // MARK: - Status check

    /// Parses `<root status_code="200">` and throws on anything else. The
    /// status code is sometimes returned as a 32-bit overflowing value on
    /// quirky GFE 3.20.3 builds - we parse as UInt32 then narrow.
    static func verifyStatus(_ xml: XMLNode) throws {
        guard let root = xml.firstChild(named: "root") else {
            throw StreamError.launchFailed("Response missing <root> element")
        }
        let codeRaw = root.attributes["status_code"] ?? "-1"
        let code: Int
        if let unsigned = UInt32(codeRaw) {
            code = Int(Int32(bitPattern: unsigned))
        } else {
            code = Int(codeRaw) ?? -1
        }
        if code == 200 { return }

        let message = root.attributes["status_message"] ?? "Status \(code)"
        // 401 over HTTPS means "unpaired" - the caller (fetchServerInfo, the
        // pairing handshake) knows how to recover, so we surface it through
        // hostUnreachable to trigger the HTTP fallback path.
        if code == 401 {
            throw StreamError.hostUnreachable("Host requires pairing (\(message))")
        }
        throw StreamError.launchFailed("\(message) (code \(code))")
    }

    // MARK: - Codec mode decoding

    /// Sunshine/GFE pack supported codecs into ServerCodecModeSupport as a
    /// bitfield. The values aren't documented anywhere except the moonlight
    /// source - here they are, copied verbatim:
    ///   bit 0    : H.264 (always implicitly supported)
    ///   bit 8    : HEVC
    ///   bit 9    : HEVC Main10
    ///   bit 16   : AV1 Main8
    ///   bit 17   : AV1 Main10
    static func decodeCodecMode(_ raw: Int) -> VideoFormats {
        var out: VideoFormats = [.h264]   // h.264 is always supported
        if raw & (1 << 8)  != 0 { out.insert(.hevc) }
        if raw & (1 << 9)  != 0 { out.insert(.hevcMain10) }
        if raw & (1 << 16) != 0 { out.insert(.av1) }
        if raw & (1 << 17) != 0 { out.insert(.av1Main10) }
        return out
    }

    // MARK: - Small helpers

    public static let controlTimeout: TimeInterval = 5
    static let launchTimeout: TimeInterval = 20
    static let resumeTimeout: TimeInterval = 20
    /// Pairing requests block on host-side state that's gated on a HUMAN typing
    /// the PIN into the host's pairing page - so the snappy 5s control timeout
    /// is far too short (the request fires the moment the code is shown, then
    /// waits for the user to read + type it). Moonlight uses a similarly long
    /// pairing window. 60s is comfortably human-scale.
    static let pairTimeout: TimeInterval = 60

    /// The literal `uniqueid` value sent on every request to the host. Must
    /// match moonlight-qt exactly - see comment in `rawRequest`.
    static let wireUniqueID = "0123456789ABCDEF"

    /// Per-request nonce. GFE uses a Qt UUID's raw 16 bytes hex-encoded; we
    /// match that exactly so packet captures look the same. Backed by
    /// SecRandomCopyBytes - not Swift's UInt8.random, which uses a non-CSPRNG.
    static func requestNonce() -> String {
        let bytes = secureRandomBytes(16)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Cryptographically-secure random bytes. The remote-input AES key + IV
    /// flow through here - using anything weaker leaks input session entropy.
    static func randomBytes(_ count: Int) -> Data {
        Data(secureRandomBytes(count))
    }

    static func secureRandomBytes(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = bytes.withUnsafeMutableBufferPointer { buf -> Int32 in
            guard let baseAddress = buf.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, buf.count, baseAddress)
        }
        if status != errSecSuccess {
            // SecRandomCopyBytes is essentially infallible on macOS, but if
            // the kernel CSPRNG ever refused us we can't usefully continue.
            // Falling back to arc4random_buf which is also CSPRNG-backed.
            bytes.withUnsafeMutableBufferPointer { buf in
                arc4random_buf(buf.baseAddress, buf.count)
            }
        }
        return bytes
    }

    static func bigEndianInt32(from data: Data) -> Int32 {
        // Take the first 4 bytes of the IV, big-endian, as a signed 32-bit
        // integer. This is what moonlight-common-c puts in rikeyid.
        guard data.count >= 4 else { return 0 }
        let b0 = UInt32(data[data.startIndex])
        let b1 = UInt32(data[data.startIndex + 1])
        let b2 = UInt32(data[data.startIndex + 2])
        let b3 = UInt32(data[data.startIndex + 3])
        let value = (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
        return Int32(bitPattern: value)
    }

    static func hexDecode(_ string: String) -> Data? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(trimmed.count / 2)
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            let next = trimmed.index(index, offsetBy: 2)
            guard let byte = UInt8(trimmed[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }
}
