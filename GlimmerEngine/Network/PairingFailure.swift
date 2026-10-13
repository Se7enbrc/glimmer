// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

public enum PairingFailure: Error, Equatable, Sendable {
    case invalidAddress
    case unreachable
    case gameStream
    case timedOut
    case busy
    case rejected
}
