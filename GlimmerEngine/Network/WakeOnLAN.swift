// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

public enum WakeOnLAN {
    package typealias Target = (host: String, ports: [UInt16])

    package static let ports: [UInt16] = [9, 47009]
    /// Sunshine's streaming ports, sent to the PC's own addresses only: a router
    /// forwarding them carries the packet to a PC reached from outside the network.
    package static let sunshinePorts: [UInt16] = [47998, 47999, 48000, 48002, 48010]
    package static let limitedBroadcast = "255.255.255.255"

    /// "aa:bb:cc:dd:ee:ff" from any separator or case; nil for junk or all zeros.
    public nonisolated static func normalizeMac(_ raw: String?) -> String? {
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
    public static func magicPacket(mac: String) -> Data? {
        guard let normalized = normalizeMac(mac) else { return nil }
        let bytes = normalized.split(separator: ":").compactMap { UInt8($0, radix: 16) }
        guard bytes.count == 6 else { return nil }
        var packet = Data(repeating: 0xFF, count: 6)
        for _ in 0..<16 { packet.append(contentsOf: bytes) }
        return packet
    }

    /// Every distinct place worth sending to, in order: the limited broadcast,
    /// each interface's subnet broadcast, then the PC's own addresses.
    package static func targets(hostAddresses: [String?], broadcasts: [String]) -> [Target] {
        var seen: Set<String> = []
        func distinct(_ addresses: [String], ports: [UInt16]) -> [Target] {
            addresses.map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
                .map { ($0, ports) }
        }
        return distinct([limitedBroadcast] + broadcasts, ports: ports)
            + distinct(hostAddresses.compactMap { $0 }, ports: ports + sunshinePorts)
    }
}
