// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  TerminationGate.swift
//
//  The quit-time rule for a live stream: the process must not exit before the
//  session's `/cancel` reaches the host, and a hung host must not be able to
//  pin Cmd-Q. `applicationShouldTerminate` answers `.terminateLater` while a
//  session is up, runs the stop under `runBounded`, then replies - so a host
//  that answers in 80 ms costs 80 ms and one that never answers costs the
//  bound. Pure and testable: no AppKit beyond the reply enum.
//
//  The bug this closes (issue #84): quitting mid-stream returned
//  `.terminateNow` after kicking off an async stop, so the process exited
//  before `/cancel` was sent and Sunshine kept a phantom session that blocked
//  the next `/launch`.
//

import GlimmerEngine
import AppKit
import Foundation

enum TerminationGate {
    /// How long a quit waits for the session stop (`backend.stopConnection` +
    /// `/cancel`) before exiting anyway. Two seconds covers a LAN round trip
    /// with a wide margin and is short enough that a dead host doesn't make
    /// Cmd-Q feel broken.
    static let stopBoundSeconds = SessionDeadline.stopBoundSeconds

    /// The reply to `applicationShouldTerminate`: defer while a session object
    /// exists (live, connecting, or still tearing down), else quit now.
    static func reply(hasSession: Bool) -> NSApplication.TerminateReply {
        hasSession ? .terminateLater : .terminateNow
    }

    static func runBounded(
        seconds: TimeInterval, _ operation: @escaping @Sendable () async -> Void
    ) async -> Bool {
        await SessionDeadline.runBounded(seconds: seconds, operation)
    }
}
