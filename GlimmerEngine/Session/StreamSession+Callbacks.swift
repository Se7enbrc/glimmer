// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  StreamSession+Callbacks.swift
//
//  Connection-edge side effects driven by the native engine's stage callbacks:
//  the InputForwarder-ready flip and the ConnectFlow signpost close. Split out
//  of StreamSession.swift to keep each unit focused.
//

import Foundation
import os

extension StreamSession {
    // MARK: - Connection edges

    /// The input uplink only accepts packets after connection, so the input
    /// forwarder buffers state until `setReady(true)` allows packets through.
    package func nativeConnectionEstablished(from source: NativeBackend) {
        guard source === backend, isStreaming, !stopInProgress else { return }
        // Ground truth that we reached a LIVE state; only a full stop resets it.
        reachedLiveState = true
        let inp = bitrateChange == nil ? input : nil
        // FIFO main-queue hop (NOT Task{}) keeps a terminate's setReady(false)
        // from reordering ahead of establish and leaving input disabled.
        let gate = bridge
        let attempt = attemptID
        DispatchQueue.main.async { MainActor.assumeIsolated {
            if gate?.acceptsInput(attempt: attempt) == true { inp?.setReady(true) }
        } }
        #if os(macOS)
        if let state = connectFlowState {
            OSSignposter.network.endInterval(
                "ConnectFlow", state, "outcome=established")
            connectFlowState = nil
        }
        #endif
    }
}
