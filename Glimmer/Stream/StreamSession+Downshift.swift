//
//  StreamSession+Downshift.swift
//
//  The watchdog escalation tier that ends an unproductive HOLD by lowering the
//  session bitrate. Split out of StreamSession+Watchdog.swift to keep that file
//  focused on detection; the POLICY (remote-only, sustained, bounded, cooled
//  down) lives in BitrateDownshiftController, and this owns the side effects.
//
//  See BitrateDownshiftController for why a reconnect is the mechanism rather
//  than a control message: bitrate is fixed per session and the SDP is the only
//  place it is ever set, so rebuilding the SDP is the only way to change it.
//

import Foundation
import os

extension StreamSession {

    /// Consider walking the bitrate down because a remote path demonstrably
    /// cannot carry the negotiated rate. The decision (remote-only, sustained,
    /// bounded, cooled-down) is the controller's; this owns the side effects -
    /// rewriting the config the reconnect will rebuild from, and driving the
    /// reconnect episode itself.
    ///
    /// `reconnectConfig` is the SAME value `reconnectInPlace` reads to build the
    /// next SDP, so lowering `bitrateKbps` here IS the downshift - there is no
    /// separate channel to push a rate through. The reconnect holds the frozen
    /// frame, so the user sees a brief hold rather than a bounce to the launcher.
    func considerBitrateDownshift(
        decodeIdle: Double, receiveIdle: Double
    ) async {
        guard isStreaming, !stopInProgress, !isReconnecting else { return }
        guard let current = reconnectConfig?.bitrateKbps else { return }

        let decision = downshift.evaluate(
            isRemote: isRemotePathSession,
            decodeIdle: decodeIdle,
            receiveIdle: receiveIdle,
            currentKbps: current,
            nowUptime: ProcessInfo.processInfo.systemUptime)

        guard case .downshift(let toKbps) = decision else {
            // Log the honest reason ONCE per stall episode - a declined
            // downshift every second would bury the log.
            if !didLogDownshiftDecision {
                didLogDownshiftDecision = true
                Diag.notice(
                    "Bitrate downshift not taken (\(decision)) - stalled \(String(format: "%.0f", decodeIdle))s "
                    + "at \(current / 1000) Mbps, remote=\(isRemotePathSession)", "Stream")
            }
            return
        }

        // Spend the budget BEFORE the await so a second watchdog tick landing
        // mid-reconnect can't book a second downshift off the same evidence.
        downshift.recordDownshift(atUptime: ProcessInfo.processInfo.systemUptime)
        reconnectConfig?.bitrateKbps = toKbps
        didLogDownshiftDecision = true

        Diag.warn(
            "Link cannot carry \(current / 1000) Mbps - \(String(format: "%.0f", decodeIdle))s of "
            + "received-but-undecodable video on a remote path. Downshifting to \(toKbps / 1000) Mbps "
            + "and reconnecting in place (step \(downshift.downshiftCount)/"
            + "\(BitrateDownshiftController.maxDownshifts)).", "Stream")
        log.error("""
            Bitrate downshift: \(current, privacy: .public) → \(toKbps, privacy: .public) kbps \
            after \(decodeIdle, privacy: .public)s decode-only stall on a remote path
            """)

        await runDownshiftReconnect(toKbps: toKbps)
    }
}
