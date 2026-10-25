// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

extension AudioDecoder {
    /// Five milliseconds of PCM ramp at Sunshine's 48 kHz input; the graph stays alive during the ramp.
    package func prepareReconnectFade() -> Duration {
        beginGraphChange()
        defer { endGraphChange() }
        reconnectFadeIn = true
        halOutput?.queue.pointee.fadingOut.store(true, ordering: .releasing)
        let latency = halOutput?.latencyMs ?? 0
        return .milliseconds(20 + (latency.isFinite ? max(0, latency) : 0))
    }

    package var renderTimes: (first: Double?, last: Double?) {
        graphChangeLock.lock()
        defer { graphChangeLock.unlock() }
        guard let queue = halOutput?.queue else { return (nil, nil) }
        let first = queue.pointee.firstRenderHostTime.load(ordering: .relaxed)
        let last = queue.pointee.lastRenderHostTime.load(ordering: .relaxed)
        return (first > 0 ? Double(first) * SocketTimestamp.millisecondsPerTick / 1_000 : nil,
                last > 0 ? Double(last) * SocketTimestamp.millisecondsPerTick / 1_000 : nil)
    }
}
