// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import os

// MARK: - ConnectionEvents adapter for the native stack

/// Weak bridge/backend references identify this attempt; sessionEvents guards the ordered task tail.
/// Receive threads yield directly to the Sendable continuation; HDR preserves the main-queue FIFO.
package final class NativeConnectionEvents: ConnectionEvents, @unchecked Sendable {
    private static let logCategory = "NativeConnection"
    /// The session this pipeline started for, not whichever is current when a late event fires.
    weak let bridge: StreamBridgeContext?
    weak let backend: NativeBackend?
    // Native callback threads access the task tail only under this lock and never wait on it.
    private let attempt: UUID
    private let feedback: SessionFeedback
    private let sessionEvents = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    package init(bridge: StreamBridgeContext? = StreamBridgeContext.current, backend: NativeBackend? = nil,
                 feedback: SessionFeedback? = nil) {
        self.bridge = bridge
        self.backend = backend
        self.attempt = bridge?.currentAttempt ?? UUID()
        self.feedback = feedback ?? bridge?.feedback ?? SessionFeedback()
    }

    /// Separate Tasks can reorder establish and terminate; chain this pipeline's actor events.
    private func enqueueSessionEvent(_ operation: @escaping @Sendable () async -> Void) {
        sessionEvents.withLock { previous in
            let predecessor = previous
            previous = Task {
                await predecessor?.value
                await operation()
            }
        }
    }

    func drainSessionEvents() async {
        await sessionEvents.withLock { $0 }?.value
    }

    private func emit(_ event: StreamEvent) {
        bridge?.emit(event, source: backend, attempt: attempt)
    }

    private var isCurrent: Bool { bridge?.acceptsEvent(from: backend, attempt: attempt) ?? false }

    package func stageStarting(_ name: String) {
        guard isCurrent else { return }
        Diag.info("stage starting: \(name)", Self.logCategory)
        // P2 CONNECT-HANDSHAKE breakdown (always-live; off any hot path - a stage
        // edge is the rarest event). Stamp the connect-relative instant of the
        // stages that bound the breakdown legs. Name-matched against the engine's
        // own stage labels (performRtspStage / performControlStage).
        let now = TelemetryCounters.monotonicNowNanos()
        let p2 = TelemetryCounters.shared.p2
        if name == "name resolution" { p2.markRtspStart(now) }
        if name == "ENET_CONNECT" { p2.markEnetStart(now) }
        emit(.stageStarting(name: name))
    }

    package func stageComplete(_ name: String) {
        guard isCurrent else { return }
        Diag.info("stage complete: \(name)", Self.logCategory)
        // P2 CONNECT-HANDSHAKE: the RTSP-done edge bounds the RTSP leg + the start
        // of the pairing/auth leg (RTSP-done → ENet-connect start, where the
        // control crypto + control-V2 negotiation set up the per-session material).
        if name == "RTSP handshake" {
            TelemetryCounters.shared.p2.markRtspDone(TelemetryCounters.monotonicNowNanos())
        }
        emit(.stageComplete(name: name))
    }

    package func stageFailed(_ name: String, code: Int32) {
        guard isCurrent else { return }
        Diag.error("stage FAILED: \(name) (code \(code))", Self.logCategory)
        emit(.stageFailed(name: name, errorCode: code))
    }

    package func connectionStarted() {
        guard isCurrent else { return }
        Diag.notice("connection established (native)", Self.logCategory)
        // P2 established edge: bounds the ENet-connect leg, starts the first-frame
        // leg. Reconnect is NOT inferred here (silent-reconnect resets the timeline
        // per attempt) - it's counted at the recovery site (runReconnectEpisode).
        TelemetryCounters.shared.p2.markEstablished()
        let bridge = self.bridge
        // If the continuation is gone at yield time, this established edge fires
        // into the void and the UI's connecting→streaming promotion falls back to
        // .firstFrame; log it so a torn yield is diagnosable (not load-bearing).
        if bridge?.eventContinuation == nil, bridge?.publicEvents == nil {
            Diag.error("connection established but event continuation is nil "
                + "(bridge=\(bridge == nil ? "nil" : "live")) - relying on first-frame fallback "
                + "to promote streaming", Self.logCategory)
        }
        emit(.connectionEstablished)
        // Drive the actor side effect (flip InputForwarder ready,
        // close the ConnectFlow signpost). Best-effort; lossy if torn down.
        if let session = bridge?.session, let backend {
            enqueueSessionEvent { await session.nativeConnectionEstablished(from: backend) }
        }
    }

    package func connectionTerminated(code: Int32) {
        guard isCurrent else { return }
        if code == 0 {
            Diag.notice("connection terminated cleanly (native)", Self.logCategory)
        } else {
            Diag.error("connection terminated unexpectedly (native, code \(code))", Self.logCategory)
        }
        // Latch the per-session reason ordinal only (code 0 → clean, else error).
        // The process-global tally is bumped at genuine teardown, NOT here - a
        // recoverable terminate may be silently reconnected (would over-count).
        TelemetryCounters.shared.p2.setDisconnectReason(
            code == 0 ? .hostClosedClean : .hostError)
        let bridge = self.bridge
        // Don't yield `.connectionTerminated` directly: handleHostTerminate
        // classifies it (a recoverable live-session close drives a silent reconnect
        // under the frozen frame). No session → fall back so it's never swallowed.
        if let session = bridge?.session, let backend {
            enqueueSessionEvent { await session.handleHostTerminate(code: code, from: backend) }
        } else {
            emit(.connectionTerminated(errorCode: code))
        }
    }

    package func connectionStatus(poor: Bool) {
        guard isCurrent else { return }
        let quality: ConnectionQuality = poor ? .poor : .good
        emit(.connectionStatus(quality))
    }

    package func controllersActivated() {
        guard isCurrent else { return }
        feedback.activated(backend)
    }

    package func controllersDeactivated() {
        guard isCurrent else { return }
        feedback.deactivated()
    }

    package func audioFailed(_ detail: String) {
        guard isCurrent else { return }
        emit(.audioFailed(detail))
    }

    package func setHdrMode(_ enabled: Bool) {
        guard isCurrent else { return }
        let decoder = bridge?.videoDecoder
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                guard isCurrent else { return }
                decoder?.setHDR(enabled: enabled)
            }
        }
        // Keep the UI edge in the receive-thread FIFO; display updates retain the main-queue hop.
        emit(.hdrModeChanged(enabled))
    }
}

// MARK: - ConnectionEvents controller feedback → the actuator

extension NativeConnectionEvents {
    /// The native event adapter's controller-feedback slots, routing host
    /// control events into the haptics/light actuator and the motion sampler.
    /// All four are declared protocol REQUIREMENTS on ConnectionEvents
    /// (StreamingBackend.swift), so these implementations are reached through
    /// the witness table even at an `any ConnectionEvents` call site - the
    /// no-op defaults exist only to keep actuator-less conformers
    /// source-compatible. Lives here, beside the startVideoStage wiring that
    /// feeds it, rather than in the (size-capped) actuator file.
    package func rumble(controller: UInt16, lowFreq: UInt16, highFreq: UInt16) {
        guard isCurrent else { return }
        feedback.rumble(controller, lowFreq, highFreq)
    }

    package func rumbleTriggers(controller: UInt16, left: UInt16, right: UInt16) {
        guard isCurrent else { return }
        feedback.triggers(controller, left, right)
    }

    package func setControllerLED(controller: UInt16, r: UInt8, g: UInt8, b: UInt8) {
        guard isCurrent else { return }
        feedback.rgb(controller, r, g, b)
    }

    package func setPlayerLEDs(controller: UInt16, solid: UInt8, flashing: UInt8) {
        guard isCurrent else { return }
        feedback.player(controller, solid, flashing)
    }

    package func setMotionEventState(controller: UInt16, motionType: UInt8, reportRateHz: UInt16) {
        guard isCurrent else { return }
        feedback.motion(controller, motionType, reportRateHz)
    }

    /// SET_ADAPTIVE_TRIGGERS (0x5503) to the bound pad's OUTPUT report: GameController
    /// has no adaptive-trigger API, so this is the one feedback that must take the
    /// raw-HID path. A no-op when the feature is off or the write is refused.
    package func setAdaptiveTriggers(controller: UInt16, eventFlags: UInt8,
                                     typeLeft: UInt8, typeRight: UInt8,
                                     left: [UInt8], right: [UInt8]) {
        guard isCurrent else { return }
        feedback.adaptive(controller, eventFlags, typeLeft, typeRight, left, right)
    }
}
