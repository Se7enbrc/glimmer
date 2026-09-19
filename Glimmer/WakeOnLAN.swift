//
//  WakeOnLAN.swift
//
//  Wake-on-LAN the way Moonlight does it: a magic packet built from the MAC
//  Sunshine reported, sent to the broadcast addresses of every interface and
//  to the PC's known addresses on ports 9 and 47009. Plain UDP, no helper.
//

import Darwin
import Foundation

enum WakeOnLAN {
    static let ports: [UInt16] = [9, 47009]
    static let limitedBroadcast = "255.255.255.255"

    /// "aa:bb:cc:dd:ee:ff" from any separator or case; nil for junk or all zeros.
    nonisolated static func normalizeMac(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let parts = raw.lowercased()
            .split(whereSeparator: { $0 == ":" || $0 == "-" })
            .map { $0.count == 1 ? "0\($0)" : String($0) }
        guard parts.count == 6,
              parts.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isHexDigit) }) else {
            return nil
        }
        let joined = parts.joined(separator: ":")
        return joined == "00:00:00:00:00:00" ? nil : joined
    }

    /// Six 0xFF bytes, then the MAC sixteen times: 102 bytes.
    static func magicPacket(mac: String) -> Data? {
        guard let normalized = normalizeMac(mac) else { return nil }
        let bytes = normalized.split(separator: ":").compactMap { UInt8($0, radix: 16) }
        guard bytes.count == 6 else { return nil }
        var packet = Data(repeating: 0xFF, count: 6)
        for _ in 0..<16 { packet.append(contentsOf: bytes) }
        return packet
    }

    /// Every distinct place worth sending to, in order: the limited broadcast,
    /// each interface's subnet broadcast, then the PC's own addresses.
    static func targets(hostAddresses: [String?], broadcasts: [String]) -> [(host: String, port: UInt16)] {
        var seen: Set<String> = []
        var hosts: [String] = []
        for address in [limitedBroadcast] + broadcasts + hostAddresses.compactMap({ $0 }) {
            let trimmed = address.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            hosts.append(trimmed)
        }
        return hosts.flatMap { host in ports.map { (host, $0) } }
    }

    /// IPv4 broadcast addresses of the Mac's live interfaces.
    static func interfaceBroadcastAddresses() -> [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var result: [String] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_BROADCAST != 0, flags & IFF_LOOPBACK == 0,
                  let broadcast = entry.pointee.ifa_dstaddr, broadcast.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }
            var address = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(broadcast, socklen_t(broadcast.pointee.sa_len), &address, socklen_t(address.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                let bytes = address.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                if let text = String(bytes: bytes, encoding: .utf8) { result.append(text) }
            }
        }
        return result
    }

    /// Send the packet to every target; returns how many sends succeeded.
    /// Hostnames resolve here, so callers run this off the main thread.
    static func send(mac: String, hostAddresses: [String?]) -> Int {
        guard let packet = magicPacket(mac: mac) else { return 0 }
        let socketFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socketFD >= 0 else { return 0 }
        defer { close(socketFD) }
        var enable: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_BROADCAST, &enable, socklen_t(MemoryLayout<Int32>.size))
        var sent = 0
        for target in targets(hostAddresses: hostAddresses, broadcasts: interfaceBroadcastAddresses()) {
            var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_DGRAM, ai_protocol: IPPROTO_UDP,
                                 ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
            var info: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(target.host, String(target.port), &hints, &info) == 0, let resolved = info else { continue }
            defer { freeaddrinfo(info) }
            let result = packet.withUnsafeBytes { buffer in
                sendto(socketFD, buffer.baseAddress, buffer.count, 0, resolved.pointee.ai_addr, resolved.pointee.ai_addrlen)
            }
            if result == packet.count { sent += 1 }
        }
        return sent
    }
}
