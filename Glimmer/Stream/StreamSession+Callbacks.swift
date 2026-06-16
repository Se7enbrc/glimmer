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

    /// Actor-isolated side effects for connection-edge events. The event has
    /// already been yielded to the stream by `NativeConnectionEvents` — this
    /// handles state that must be touched on the actor (signpost-interval close)
    /// or hopped to MainActor (InputForwarder gate flip).
    ///
    /// The input uplink only accepts packets after the connection is
    /// established (send* returns -2 otherwise), so the InputForwarder buffers
    /// its state and starts forwarding only when we tell it via `setReady(true)`.
    fileprivate func handleConnectionEdge(_ event: StreamEvent) {
        switch event {
        case .connectionEstablished:
            // Ground truth that we reached a LIVE state — gates the silent
            // reconnect (a terminate before this is a failed connect, not a
            // recoverable interruption). Fires again on every reconnect; never
            // reset until a full stop().
            reachedLiveState = true
            let inp = input
            Task { @MainActor in inp?.setReady(true) }
            if let state = connectFlowState {
                OSSignposter.network.endInterval(
                    "ConnectFlow", state, "outcome=established")
                connectFlowState = nil
            }
        case .connectionTerminated:
            let inp = input
            Task { @MainActor in inp?.setReady(false) }
        default:
            break
        }
    }

    /// Native-engine connection-edge hooks. The NativeConnectionEvents adapter
    /// yields the StreamEvents the consumer + event stream observe, then calls
    /// these to run the actor-isolated side effects (the InputForwarder-ready
    /// flip and the ConnectFlow signpost close) through `handleConnectionEdge`.
    func nativeConnectionEstablished() {
        handleConnectionEdge(.connectionEstablished)
    }

    func nativeConnectionTerminated() {
        handleConnectionEdge(.connectionTerminated(errorCode: 0))
    }
}
