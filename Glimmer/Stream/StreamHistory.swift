//
//  StreamHistory.swift
//
//  The last minute of the stream at one sample per second (bandwidth in,
//  frames arriving, round-trip latency) for the menu bar panel's chart. Fed
//  by the stats overlay timer that already runs every session; reset at launch.
//

import Foundation
import Observation

@MainActor @Observable
final class StreamHistory {
    static let shared = StreamHistory()
    static let capacity = 60

    private(set) var mbps: [Double] = []
    private(set) var fps: [Double] = []
    private(set) var rttMs: [Double] = []

    func append(mbps bandwidth: Double?, fps sample: Double?, rttMs latency: Double?) {
        mbps.append(bandwidth ?? 0)
        fps.append(sample ?? 0)
        rttMs.append(latency ?? 0)
        if mbps.count > Self.capacity { mbps.removeFirst(mbps.count - Self.capacity) }
        if fps.count > Self.capacity { fps.removeFirst(fps.count - Self.capacity) }
        if rttMs.count > Self.capacity { rttMs.removeFirst(rttMs.count - Self.capacity) }
    }

    func reset() {
        mbps.removeAll()
        fps.removeAll()
        rttMs.removeAll()
    }
}

/// Counts the overlay timer's 250 ms ticks and records one sample a second.
@MainActor final class StreamHistoryFeed {
    private var ticks = 0

    func tick(mbps: Double?, fps: Double?, rttMs: Double?) {
        ticks += 1
        guard ticks % 4 == 0 else { return }
        StreamHistory.shared.append(mbps: mbps, fps: fps, rttMs: rttMs)
    }
}
