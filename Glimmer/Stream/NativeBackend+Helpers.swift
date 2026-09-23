//
//  NativeBackend+Helpers.swift
//
//  Pure static helpers faithful to RtspConnection.c / Misc.c: RTSP port and
//  address-family derivation. Split out of NativeBackend.swift to keep each unit focused.
//

import Foundation

extension NativeBackend {
    // MARK: - Helpers (faithful to RtspConnection.c / Misc.c)

    /// RtspPortNumber = last ':' integer of rtspSessionUrl, else 48010.
    static func rtspPort(from rtspSessionUrl: String) -> UInt16 {
        guard let colon = rtspSessionUrl.lastIndex(of: ":") else { return 48010 }
        let after = rtspSessionUrl[rtspSessionUrl.index(after: colon)...]
        let digits = after.prefix(while: { $0.isNumber })
        if let port = Int(digits), port > 0, port <= 65535 { return UInt16(port) }
        return 48010
    }

    /// Derive (urlAddr for Host: header, urlSafeAddr for SDP o=, "IPv4"/"IPv6"
    /// family token). Prefer the host portion of the rtspSessionUrl; else the
    /// raw server address. IPv6 literals are bracketed for urlSafeAddr.
    static func addressInfo(rtspSessionUrl: String, fallbackAddress: String)
        -> (urlAddr: String, urlSafeAddr: String, familyToken: String) {
        let rawHost = hostPortion(of: rtspSessionUrl) ?? fallbackAddress
        let isIPv6 = rawHost.contains(":") && !rawHost.contains(".")
            ? true
            : rawHost.contains(":")  // bracketed/colon-bearing → treat as IPv6
        let family = isIPv6 ? "IPv6" : "IPv4"
        // urlAddr is the bare host (no brackets) for the Host: header.
        let bare = rawHost.replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
        let urlSafe = isIPv6 ? "[\(bare)]" : bare
        return (bare, urlSafe, family)
    }

    /// Extract the host portion from "rtsp://HOST:PORT" (handles bracketed IPv6).
    static func hostPortion(of url: String) -> String? {
        guard let schemeRange = url.range(of: "://") else { return nil }
        var rest = String(url[schemeRange.upperBound...])
        // Strip trailing path.
        if let slash = rest.firstIndex(of: "/") { rest = String(rest[rest.startIndex..<slash]) }
        if rest.hasPrefix("[") {
            // [IPv6]:port
            if let close = rest.firstIndex(of: "]") {
                return String(rest[rest.index(after: rest.startIndex)..<close])
            }
            return rest
        }
        // host:port - strip the last :port.
        if let colon = rest.lastIndex(of: ":") {
            return String(rest[rest.startIndex..<colon])
        }
        return rest
    }
}
