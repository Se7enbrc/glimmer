// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Darwin
import Foundation

/// Only error/stop edges take this lock; successful datagrams never do.
final class AudioReceiveFailure: @unchecked Sendable {
    enum Action: Equatable {
        case quiet
        case interrupted
        case pressure
        case failed
        case stopped
    }

    private let lock = NSLock()
    private var cancelled = false
    private var terminalError: Int32?

    var failure: Int32? {
        lock.withLock { terminalError }
    }

    func cancel() {
        lock.withLock { cancelled = true }
    }

    func action(for error: Int32) -> Action {
        lock.withLock {
            guard !cancelled, terminalError == nil else { return .stopped }
            switch error {
            case EAGAIN, EWOULDBLOCK: return .quiet
            case EINTR: return .interrupted
            case ENOBUFS, ENOMEM: return .pressure
            default:
                terminalError = error
                return .failed
            }
        }
    }
}
