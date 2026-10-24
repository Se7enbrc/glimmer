// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Darwin
import Foundation
import GlimmerEngine

extension WakeOnLAN {
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

    /// Send the packet to every target; returns how many sends succeeded. Each
    /// address resolves once, here, so callers run this off the main thread.
    static func send(mac: String, hostAddresses: [String?]) -> Int {
        send(mac: mac, to: targets(hostAddresses: hostAddresses, broadcasts: interfaceBroadcastAddresses()))
    }

    /// Send the packet to each target and port; tests aim this at a loopback listener.
    static func send(mac: String, to targets: [Target]) -> Int {
        guard let packet = magicPacket(mac: mac) else { return 0 }
        let socketFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socketFD >= 0 else { return 0 }
        defer { close(socketFD) }
        var enable: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_BROADCAST, &enable, socklen_t(MemoryLayout<Int32>.size))
        var sent = 0
        for target in targets {
            guard var address = resolveIPv4(target.host) else { continue }
            for port in target.ports {
                address.sin_port = port.bigEndian
                let result = withUnsafePointer(to: address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                        packet.withUnsafeBytes { buffer in
                            sendto(socketFD, buffer.baseAddress, buffer.count, 0, socketAddress,
                                   socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
                if result == packet.count { sent += 1 }
            }
        }
        return sent
    }

    private static func resolveIPv4(_ host: String) -> sockaddr_in? {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_DGRAM, ai_protocol: IPPROTO_UDP,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &info) == 0, let resolved = info else { return nil }
        defer { freeaddrinfo(resolved) }
        return resolved.pointee.ai_addr?.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
    }
}
