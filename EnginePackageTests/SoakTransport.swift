// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

struct SoakTransport {
    struct Packet: Equatable {
        let sequence: Int
        let sent: Double
        let arrival: Double
    }

    struct Faults {
        var lossEvery = 0
        var jitter = 0.0
        var reorderEvery = 0
        var reorderDelay = 0.0
    }

    static let duration = 32 * 60
    static let cycle = 120
    private(set) var pending: [Packet] = []
    private(set) var lost = 0
    private(set) var reordered = 0
    private(set) var peakPending = 0
    private var lastDelivered = -1

    static func faults(at time: Double) -> Faults {
        let phase = Int(time) % cycle
        switch phase {
        case 20..<25: return Faults(lossEvery: 17, jitter: 0.018, reorderEvery: 7, reorderDelay: 0.030)
        case 30: return Faults(lossEvery: 1)
        case 40..<45: return Faults(reorderEvery: 5, reorderDelay: 0.025)
        case 90: return Faults(lossEvery: 1)
        default: return Faults()
        }
    }

    mutating func send(sequence: Int, at time: Double, faults: Faults) {
        if faults.lossEvery > 0, sequence.isMultiple(of: faults.lossEvery) {
            lost += 1
            return
        }
        let jitter = faults.jitter * Double((sequence &* 17) % 11) / 10
        let reorder = faults.reorderEvery > 0 && sequence.isMultiple(of: faults.reorderEvery)
        let packet = Packet(sequence: sequence, sent: time,
                            arrival: time + jitter + (reorder ? faults.reorderDelay : 0))
        let position = pending.firstIndex { $0.arrival > packet.arrival } ?? pending.endIndex
        pending.insert(packet, at: position)
        peakPending = max(peakPending, pending.count)
    }

    mutating func receive(through time: Double) -> [Packet] {
        var ready: [Packet] = []
        while let first = pending.first, first.arrival <= time + 1e-9 {
            let packet = pending.removeFirst()
            if packet.sequence < lastDelivered { reordered += 1 }
            lastDelivered = max(lastDelivered, packet.sequence)
            ready.append(packet)
        }
        return ready
    }
}
