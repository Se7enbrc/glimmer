//
//  StreamSession+Downshift.swift
//
//  The watchdog escalation tier that ends an unproductive HOLD by lowering the
//  session bitrate, and the step back up once the lowered rate has run clean.
//  The POLICY (remote-only, sustained, bounded, cooled down, clean window) lives
//  in BitrateDownshiftController; this owns the side effects.
//
//  See BitrateDownshiftController for why a reconnect is the mechanism rather
//  than a control message: bitrate is fixed per session and the SDP is the only
//  place it is ever set, so rebuilding the SDP is the only way to change it.
//

import Foundation
import os

extension StreamSession {

    /// Consider walking the bitrate down because a remote path demonstrably cannot carry the negotiated
    /// rate. `reconnectConfig` is what `reconnectInPlace` builds the next SDP from, so lowering its
    /// bitrate IS the downshift; the reconnect holds the frozen frame rather than bouncing to the launcher.
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

        // Spend the budget BEFORE any await so a second watchdog tick landing
        // mid-reconnect can't book a second downshift off the same evidence.
        downshift.recordDownshift(atUptime: ProcessInfo.processInfo.systemUptime)
        reconnectConfig?.bitrateKbps = toKbps
        didLogDownshiftDecision = true
        // The route the stall was judged on, so a later route change can set the downshift aside.
        downshift.route = await currentRouteAsk()?.route
        guard isStreaming, !stopInProgress, !isReconnecting else { return }

        Diag.warn(
            "Link cannot carry \(current / 1000) Mbps - \(String(format: "%.0f", decodeIdle))s of "
            + "received-but-undecodable video on a remote path. Downshifting to \(toKbps / 1000) Mbps "
            + "and reconnecting in place (step \(downshift.stepsDown) down).", "Stream")
        log.error("""
            Bitrate downshift: \(current, privacy: .public) → \(toKbps, privacy: .public) kbps \
            after \(decodeIdle, privacy: .public)s decode-only stall on a remote path
            """)

        await runSelfInitiatedReconnect(
            cause: "lowering the bitrate to \(toKbps / 1000) Mbps",
            bannerText: "Weak connection. Lowering quality to \(toKbps / 1000) Mbps…")
    }

    /// After a clean window at a lowered rate, one step back toward the route's ask, applied the way the
    /// downshift was: a reconnect in place under a banner that says why. Called on healthy watchdog ticks.
    func considerBitrateStepUp() async {
        guard isStreaming, !stopInProgress, !isReconnecting, downshift.isDownshifted,
              let current = reconnectConfig?.bitrateKbps else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // The clean window is checked before the main-actor hop for the route, so the hop is rare.
        guard downshift.stepUp(currentKbps: current, routeKbps: .max, nowUptime: now) != nil else { return }
        let route = await currentRouteAsk()
        guard isStreaming, !stopInProgress, !isReconnecting, let route, downshift.covers(route: route.route),
              let toKbps = downshift.stepUp(currentKbps: current, routeKbps: route.kbps, nowUptime: now)
        else { return }
        let clean = downshift.cleanSeconds(nowUptime: now) ?? 0
        downshift.recordStepUp(atUptime: now, reachedRoute: toKbps >= route.kbps)
        reconnectConfig?.bitrateKbps = toKbps

        Diag.notice("Link clean for \(Int(clean / 60)) min at \(current / 1000) Mbps - stepping back up to "
            + "\(toKbps / 1000) Mbps and reconnecting in place.", "Stream")
        log.notice("""
            Bitrate step-up: \(current, privacy: .public) → \(toKbps, privacy: .public) kbps after \
            \(clean, privacy: .public)s clean at the lowered rate
            """)
        await runSelfInitiatedReconnect(
            cause: "raising the bitrate to \(toKbps / 1000) Mbps",
            bannerText: "Connection improved. Raising quality to \(toKbps / 1000) Mbps…")
    }
}
