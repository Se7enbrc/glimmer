// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

package struct TransportPlatform: Sendable {
    package typealias ReceiveBatch = @convention(c) (Int32, UnsafeMutableRawPointer, UInt32, Int32) -> Int
    package let receiveBatch: ReceiveBatch?
    package let configureAudioThread: @Sendable () -> Void
    package let configureInputThread: @Sendable () -> Void

    package var steadyPingInterval: @Sendable () -> TimeInterval = { EnvSignalController.shared.steadyPingInterval() }
    package var audioPingStarted: @Sendable () -> Void = { EnvSignalController.shared.noteAudioPingLoopStart() }
    package var videoPingStarted: @Sendable () -> Void = { EnvSignalController.shared.noteVideoPingLoopStart() }
    package var audioPings = EnvSignalController.shared.audioPingsSentTotal
    package var videoPings = EnvSignalController.shared.videoPingsSentTotal

    package init(receiveBatch: ReceiveBatch? = nil,
                 configureAudioThread: @escaping @Sendable () -> Void = {},
                 configureInputThread: @escaping @Sendable () -> Void = {}) {
        self.receiveBatch = receiveBatch
        self.configureAudioThread = configureAudioThread
        self.configureInputThread = configureInputThread
    }
}
