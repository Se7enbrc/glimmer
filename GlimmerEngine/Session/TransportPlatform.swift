// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

package struct TransportPlatform: Sendable {
    package typealias ReceiveBatch = @convention(c) (Int32, UnsafeMutableRawPointer, UInt32, Int32) -> Int
    package let receiveBatch: ReceiveBatch?
    package let configureAudioThread: @Sendable () -> Void
    package let configureInputThread: @Sendable () -> Void

    package var steadyPingInterval: @Sendable () -> TimeInterval = { UdpPinger.steadyPingIntervalSeconds }
    package var audioPingStarted: @Sendable () -> Void = {}
    package var videoPingStarted: @Sendable () -> Void = {}
    package var audioPings = TelemetryCounters.Counter()
    package var videoPings = TelemetryCounters.Counter()

    package init(receiveBatch: ReceiveBatch? = nil,
                 configureAudioThread: @escaping @Sendable () -> Void = {},
                 configureInputThread: @escaping @Sendable () -> Void = {}) {
        self.receiveBatch = receiveBatch
        self.configureAudioThread = configureAudioThread
        self.configureInputThread = configureInputThread
    }
}
