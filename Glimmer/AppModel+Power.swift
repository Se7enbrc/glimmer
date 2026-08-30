//
//  AppModel+Power.swift
//
//  Luna power-action orchestration. The GATE, the subprocess mechanics, and
//  the whole spec (probe order, minimum luna version, MAC match, zeroed-MAC
//  fail-closed, credential-free) live in LunaPower.swift's file header - read
//  that first. This file owns the UX flows: Wake / Wake & Connect from an
//  offline tile, the user's way out of a wake that is taking too long, and the
//  online power verbs from the tile's power menu. Everything runs off the main
//  thread via LunaPower's runner; the UI stays live through the ~36s confirmed
//  wake.
//

import Foundation

extension AppModel {

    /// The in-flight `wakeHost` orchestration, so `cancelWake` can drop the
    /// post-wake Sunshine wait as well as the luna subprocess. Type-level
    /// scratch: extensions can't add stored properties, and the hero runs one
    /// wake at a time by construction - the same pattern (and the same
    /// @MainActor inheritance) as the connect-cancel statics in
    /// AppModel+Streaming.swift.
    private static var wakeTask: Task<Void, Never>?

    /// Wake the host via luna (exit 0 = CONFIRMED awake, ~36s cold - no
    /// client-side power polling on top), then optionally wait for Sunshine to
    /// answer /serverinfo and start the default app - "as if the user had
    /// tapped the host". The host's encoder is known-ragged for ~15s after a
    /// cold boot (Sunshine ramp); early jitter is not failure. The wait is
    /// abandonable throughout - see `cancelWake`.
    func wakeHost(_ host: Host, device: LunaPower.Device, thenConnect: Bool) {
        Self.wakeTask?.cancel()
        Self.wakeTask = Task { @MainActor in
            do {
                try await LunaPower.shared.perform("on", deviceID: device.id, hostID: host.id)
                Diag.notice("luna: \(host.displayName) confirmed awake", "Power")
                restartHostStatusPolling()
                guard thenConnect, !Task.isCancelled else { return }
                if await waitForSunshine(host: host, budgetSeconds: 90) {
                    guard selectedHost?.id == host.id, !isStreaming else { return }
                    streamDefaultApp()
                } else if !Task.isCancelled {
                    Diag.notice("luna: \(host.displayName) awake but Sunshine did not "
                        + "answer within 90s - not auto-connecting", "Power")
                }
            } catch is CancellationError {
                // The user abandoned the wait. `cancelWake` already wrote the
                // breadcrumb and LunaPower deliberately recorded no
                // lastActionError, so there is nothing to log and nothing to
                // show - the tile falls straight back to offline + Wake.
            } catch {
                // LunaPower recorded lastActionError for the tile subtext.
                Diag.notice("luna: wake \(host.displayName) failed - "
                    + "\(error.localizedDescription)", "Power")
            }
        }
    }

    /// Abandon an in-flight wake - the user's way out of luna's synchronous
    /// wait, which can hold the hero's "Waking <PC>…" capsule for up to 200s.
    /// Terminates the child luna process and drops the post-wake Sunshine wait,
    /// then re-arms the poller so the tile converges on the real state (offline
    /// + Wake if the PC is still down). Abandons OUR wait only: UpSnap already
    /// has the request, so the PC may still come up on its own. Leaves no
    /// latched state - a cancel followed by a fresh Wake starts clean.
    func cancelWake(_ host: Host) {
        guard LunaPower.shared.actionInFlight[host.id] == "on" else { return }
        Diag.notice("luna: wake \(host.displayName) cancelled by the user - abandoning "
            + "the wait (UpSnap has the request; the PC may still come up)", "Power")
        Self.wakeTask?.cancel()
        Self.wakeTask = nil
        LunaPower.shared.cancelAction(hostID: host.id)
        restartHostStatusPolling()
    }

    /// Run an online power verb (off / sleep / reboot) against the host, with
    /// the poller re-armed after so the tile converges to the real state
    /// (off ~9s confirmed; the chip then reads Asleep and the wake controls
    /// return via the same gate).
    func powerAction(_ verb: String, host: Host, device: LunaPower.Device) {
        Task { @MainActor in
            do {
                try await LunaPower.shared.perform(verb, deviceID: device.id, hostID: host.id)
                Diag.notice("luna: \(verb) \(host.displayName) confirmed", "Power")
            } catch {
                Diag.notice("luna: \(verb) \(host.displayName) failed - "
                    + "\(error.localizedDescription)", "Power")
            }
            restartHostStatusPolling()
        }
    }

    /// Bounded post-wake wait for Sunshine: the DEVICE is confirmed up (luna's
    /// synchronous contract), but Sunshine's HTTP front-end takes several more
    /// seconds to come up after the OS boots. 3s-cadence /serverinfo probes -
    /// this polls the APP layer, not the power state, so it does not violate
    /// the no-polling-on-top rule.
    private func waitForSunshine(host: Host, budgetSeconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(budgetSeconds)
        let info = nativeServerInfo(for: host)
        while Date() < deadline {
            let client = NetworkClient(server: info)
            let answered = (try? await client.fetchServerInfo()) != nil
            await client.shutdown()
            if answered { return true }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if Task.isCancelled { return false }
        }
        return false
    }
}
