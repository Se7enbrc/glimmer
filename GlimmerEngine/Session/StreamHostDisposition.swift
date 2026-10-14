// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

/// Required for the entire session, including recovery and late launch completion.
public enum StreamHostDisposition: Sendable {
    case disconnectOnly
    case cancelOwnedHostSession

    package var cancellation: HostCancellation? {
        switch self {
        case .disconnectOnly: nil
        case .cancelOwnedHostSession: HostCancellation()
        }
    }
}

/// Only the owned-session disposition can create this capability.
package struct HostCancellation: Sendable {
    fileprivate init() {}

    package func cancel(_ network: NetworkClient) async throws {
        try await network.cancel()
    }
}
