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
    func nativeConnectionEstablished() {
        // Ground truth that we reached a LIVE state; only a full stop resets it.
        reachedLiveState = true
        let inp = input
        // FIFO main-queue hop (NOT Task{}) keeps a terminate's setReady(false)
        // from reordering ahead of establish and leaving input disabled.
        DispatchQueue.main.async { MainActor.assumeIsolated { inp?.setReady(true) } }
        if let state = connectFlowState {
            OSSignposter.network.endInterval(
                "ConnectFlow", state, "outcome=established")
            connectFlowState = nil
        }
    }
}
