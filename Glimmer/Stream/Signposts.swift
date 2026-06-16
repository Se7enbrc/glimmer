//
//  Signposts.swift
//
//  Shared OSSignposter instances used by the Stream subsystem so Instruments
//  (Logging template) produces a meaningful end-to-end timeline without us
//  having to litter the hot paths with ad-hoc logging.
//
//  Why OSSignposter (not os_signpost macros, not os_log).
//  -----------------------------------------------------
//  OSSignposter is the Swift-native wrapper Apple introduced in macOS 12 /
//  iOS 15. It exposes typed `beginInterval` / `endInterval` / `emitEvent`
//  APIs and an `OSSignpostID` that we can thread across thread boundaries —
//  which we need, because every interesting hot path in Glimmer crosses a
//  thread boundary at least once (the VT decode callback hops dispatch
//  queues; the native backend's connection events fire on its receive
//  threads).
//
//  Cost model. Per Apple's WWDC22 talk ("Profile your app with Instruments"):
//   * ~5 ns per call when the signpost subsystem isn't being recorded
//     (the common production case — the OS gates this through the signpost
//     mux and short-circuits before any string formatting happens).
//   * ~50 ns per call when Instruments is actively recording.
//  Both numbers are dwarfed by anything else in our hot paths (a single
//  decoded frame takes 1–8 ms wall-clock at 4K60), so we leave the signposts
//  in production builds unconditionally.
//
//  Subsystem / category convention.
//  --------------------------------
//  The subsystem string matches what the Stream's Logger instances already
//  use (`io.ugfugl.Glimmer`) so Instruments shows all of our
//  os_log + os_signpost traffic under the same root node. Categories pick
//  out specific hot paths so a profile run can focus on one area:
//
//    Decode   — VTDecompressionSessionDecodeFrame submit → output callback
//    Render   — VT output callback → AVSampleBufferDisplayLayer enqueue
//    Network  — startConnection flow + per-stage connection events
//    Pairing  — five-round PIN handshake
//    Audio    — opus decode + AVAudioPlayerNode schedule
//
//  Open the .trace in Instruments → drag the "os_signpost" track in → filter
//  by subsystem `io.ugfugl.Glimmer` to see all of it at once,
//  or by category for one path. See docs/PROFILING.md for the full playbook.

import os

extension OSSignposter {

    /// Decode path: submit-into-VT → output callback fire. One interval per
    /// frame, with the bitstream byte count as the begin message and the
    /// outcome (ok / dropped / abandoned) as the end message.
    static let decode = OSSignposter(
        subsystem: "io.ugfugl.Glimmer",
        category: "Stream.Decode")

    /// Render path: VT output callback enters → renderer.enqueue() returns.
    /// One interval per successfully-decoded frame. Emits a `RendererFailed`
    /// event when the AVSampleBufferDisplayLayer latches FAILED and we have
    /// to flush + request an IDR.
    static let render = OSSignposter(
        subsystem: "io.ugfugl.Glimmer",
        category: "Stream.Render")

    /// Network path: startConnection → first connectionStarted callback,
    /// plus per-stage stageStarting/stageComplete/stageFailed events. These
    /// are the native backend's connection lifecycle markers.
    static let network = OSSignposter(
        subsystem: "io.ugfugl.Glimmer",
        category: "Stream.Network")

    /// Pairing path: full runPairingFlow as one interval, with one event per
    /// HTTP round so a stuck handshake shows the exact step that hung.
    static let pairing = OSSignposter(
        subsystem: "io.ugfugl.Glimmer",
        category: "Stream.Pairing")

    /// Audio path: opus_multistream_decode_float + scheduleBuffer. One
    /// interval per network-delivered audio packet.
    static let audio = OSSignposter(
        subsystem: "io.ugfugl.Glimmer",
        category: "Stream.Audio")
}
