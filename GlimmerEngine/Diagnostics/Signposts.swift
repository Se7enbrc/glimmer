// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// Shared signpost IDs span receive, decode and display threads without hot-path log formatting.
// Production iOS excludes signposts; stream control owns its own clocks.
// Categories and profiling instructions live in docs/PROFILING.md.

import os

extension OSSignposter {
    #if os(macOS) || GLIMMER_DIAGNOSTICS

    /// System Trace captures this standard category; custom render categories may be absent.
    package static let diagnosticClock = OSSignposter(logHandle: OSLog(
        subsystem: "io.ugfugl.Glimmer", category: .pointsOfInterest))

    /// Decode path: submit-into-VT → output callback fire. One interval per
    /// frame, with the bitstream byte count as the begin message and the
    /// outcome (ok / dropped / abandoned) as the end message.
    package static let decode = OSSignposter(
        subsystem: "io.ugfugl.Glimmer",
        category: "Stream.Decode")

    /// Render path: VT output callback enters → renderer.enqueue() returns.
    /// One interval per successfully-decoded frame. Emits a `RendererFailed`
    /// event when the AVSampleBufferDisplayLayer latches FAILED and we have
    /// to flush + request an IDR.
    package static let render = OSSignposter(
        subsystem: "io.ugfugl.Glimmer",
        category: "Stream.Render")

    /// Network path: startConnection → first connectionStarted callback,
    /// plus per-stage stageStarting/stageComplete/stageFailed events. These
    /// are the native backend's connection lifecycle markers.
    package static let network = OSSignposter(
        subsystem: "io.ugfugl.Glimmer",
        category: "Stream.Network")

    /// Pairing path: full runPairingFlow as one interval, with one event per
    /// HTTP round so a stuck handshake shows the exact step that hung.
    package static let pairing = OSSignposter(
        subsystem: "io.ugfugl.Glimmer",
        category: "Stream.Pairing")

    /// Audio path: Opus decode + scheduleBuffer. One
    /// interval per network-delivered audio packet.
    package static let audio = OSSignposter(
        subsystem: "io.ugfugl.Glimmer",
        category: "Stream.Audio")
    #endif
}
