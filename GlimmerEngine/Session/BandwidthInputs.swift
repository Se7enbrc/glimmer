// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Synchronization

/// Native callbacks publish scalar snapshots; the session reads them independently of telemetry export.
public final class BandwidthInputs: Sendable {
    public struct Snapshot: Sendable {
        public var path: BandwidthPath
        public var environment: BandwidthEnvironment
        public init(path: BandwidthPath, environment: BandwidthEnvironment) {
            self.path = path
            self.environment = environment
        }
    }

    private let state: Mutex<Snapshot>
    public init(_ initial: Snapshot) { state = Mutex(initial) }
    public func snapshot() -> Snapshot { state.withLock { $0 } }
    public func update(_ snapshot: Snapshot) { state.withLock { $0 = snapshot } }
}
