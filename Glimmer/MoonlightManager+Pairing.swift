//
//  MoonlightManager+Pairing.swift
//
//  Stream lifecycle hooks, pairing (PIN + pair flow), the Sunshine web-UI opener, and the menu-bar accessors. Split out of MoonlightManager.swift to keep each unit focused.
//

import Foundation
import AppKit
import AudioToolbox
import CoreAudio
import GameController
import SwiftUI
import Observation
import ServiceManagement
import os.log

extension MoonlightManager {

    // MARK: Stream lifecycle hooks

    func beforeStreamStart() async {
        if muteMacWhileStreaming { muteMac() }
    }

    func afterStreamEnd() async {
        // Keyed off the did-mute latch inside restoreMac() (prePausedMacVolume
        // non-nil), NOT the live muteMacWhileStreaming flag: the toggle can be
        // flipped OFF mid-stream, and the old flag-gated restore then left the
        // Mac stuck at volume 0 — with the saved level destroyed by the next
        // muted stream's re-capture of that 0. Unconditional restore keeps
        // teardown symmetric with whatever beforeStreamStart() / the live
        // toggle (applyMutePreferenceMidStream) actually did, and is a no-op
        // when nothing was muted.
        restoreMac()
    }

    /// String-typed read shim for UI code that hasn't migrated to
    /// switching on `pairingPhase`. Existing `.contains("✓")` checks keep
    /// working. Writers go through `pairingPhase`.
    var pairingMessage: String? {
        switch pairingPhase {
        case .idle:                  return nil
        case .awaitingPin(let text): return text
        case .verifying(let text):   return text
        case .success(let text):     return text
        case .failure(let text):     return text
        }
    }

    // MARK: Pairing

    /// One launchable app captured from the host's /applist right after pairing.
    /// A small named struct instead of a 4-field tuple; passed straight through
    /// to `saveHost`.
    struct PairedApp {
        let id: Int
        let name: String
        let hdr: Bool
        let hidden: Bool
    }

    /// Generate a 4-digit pairing PIN.
    ///
    /// SECURITY (#10) — note on PIN entropy:
    ///
    /// The PIN encrypts the challenge round-trip via AES-128-ECB with the
    /// key SHA-256(salt || pin)[0..16]. Per-PIN search cost is ~one
    /// SHA-256 + one AES-128 = ~1µs on contemporary hardware, so a
    /// captured pair handshake is offline-brute-forceable in ~10ms at 4
    /// digits, ~640ms at 6 digits. The protocol-level mitigation is the
    /// follow-on RSA signature: an attacker who recovers the PIN-derived
    /// key still cannot impersonate the host without the host's RSA
    /// private key. So PIN entropy is NOT the only authentication signal.
    /// The other security-pass mitigations (#4 stable pin storage,
    /// #7 fingerprint comparison on rotation, #11 commit-pin-late) close
    /// the practical attack surface that PIN brute-force would otherwise
    /// open.
    ///
    /// We deliberately keep 4 digits for protocol compatibility — GFE
    /// 3.x's pairing UI accepts any string but its pair-page may auto-
    /// submit on 4 chars (untested for 6); Sunshine accepts arbitrary
    /// length but a user typing six on a host UI that auto-submits at
    /// four is a footgun. If we ever validate 6-digit auto-submit
    /// behaviour on the current GFE + all Sunshine versions in the
    /// wild, this is the place to widen the range. The
    /// pin.count == 4 guard in `pair(hostnameOrIP:pin:)` would also need
    /// to relax to >= 4.
    func generatePairingPIN() -> String {
        let pinValue = Int.random(in: 0...9999)
        return String(format: "%04d", pinValue)
    }

    /// Pair with a host using Glimmer's native `PairingClient`. Walks the
    /// full five-round-trip handshake against the host's HTTP/HTTPS port,
    /// pins the resulting server cert, and persists the pairing so future
    /// streams skip straight to /launch.
    func pair(hostnameOrIP: String, pin: String) async {
        let pattern = #"^[A-Za-z0-9]([A-Za-z0-9._:-]*[A-Za-z0-9])?$"#
        guard hostnameOrIP.range(of: pattern, options: .regularExpression) != nil,
              hostnameOrIP.count <= 253,
              !hostnameOrIP.hasPrefix("-") else {
            pairingPhase = .failure("Hostname looks invalid. Use a name like tower.local or an IP.")
            return
        }
        guard pin.count == 4, pin.allSatisfy({ $0.isNumber }) else {
            pairingPhase = .failure("PIN must be 4 digits.")
            return
        }

        pairingInFlight = true
        pairingPhase = .awaitingPin("Pairing… enter \(pin) on \(hostnameOrIP).")

        // Stop the background chip poller for the duration of pairing. It hits
        // the host's HTTPS :47984 every few seconds; Sunshine's pairing state
        // machine is single-session, and those concurrent connections during
        // the getservercert→PIN window can wedge it (the host stops responding
        // to getservercert, and its log fills with "SSL Verification error ::
        // self-signed certificate"). moonlight-qt pauses discovery/polling
        // while pairing for the same reason. Restored in the defer below.
        hostStatusTask?.cancel()
        hostStatusTask = nil
        defer { restartHostStatusPolling() }

        var info = ServerInfo(
            address: hostnameOrIP,
            uniqueId: hostnameOrIP,
            serverName: hostnameOrIP
        )
        info.pairStatus = .unpaired

        do {
            let network = NetworkClient(server: info)
            let fetched = try await network.fetchServerInfo()
            if fetched.pairStatus == .paired {
                pairingPhase = .success("Already paired with \(hostnameOrIP). ✓")
                pairingInFlight = false
                loadHosts()
                return
            }
            let client = PairingClient(network: network, server: fetched)
            pairingPhase = .verifying("Pairing… enter \(pin) on \(hostnameOrIP).")
            let paired = try await client.pair(pin: pin)
            // Persist the host record so it survives loadHosts() — pairing only
            // pinned the cert; without this the freshly-paired PC didn't save.
            // Fetch /applist (best-effort) so the host has its launchable apps;
            // a "Desktop" fallback keeps it usable if the call fails.
            var apps: [PairedApp] = []
            do {
                let pairedClient = NetworkClient(server: paired)
                apps = try await pairedClient.appList()
                    .map { PairedApp(id: $0.id, name: $0.name, hdr: $0.hdrCapable, hidden: $0.hidden) }
            } catch {
                log.error("post-pair /applist failed: \(error.localizedDescription, privacy: .public)")
            }
            if apps.isEmpty {
                apps = [PairedApp(id: 881448767, name: "Desktop", hdr: false, hidden: false)]
            }
            saveHost(
                uuid: paired.uniqueId,
                hostname: paired.serverName.isEmpty ? hostnameOrIP : paired.serverName,
                address: hostnameOrIP,
                serverCertPEM: paired.serverCertPEM,
                appVersion: paired.appVersion,
                gfeVersion: paired.gfeVersion,
                apps: apps)
            pairingPhase = .success("Paired with \(hostnameOrIP) ✓")
            Diag.notice("Pairing succeeded", "Pairing")
        } catch let err as StreamError {
            // SECURITY (#10): the externally-visible message is uniform —
            // we don't tell the user (or an attacker watching over their
            // shoulder) whether the failure was "wrong PIN" vs "host
            // signature did not verify" vs "host returned status N".
            // The detailed cause goes to the log at `.private` so a real
            // bug report can still pull the cause via `log show`.
            log.error("Pairing failed for host=\(hostnameOrIP, privacy: .private(mask: .hash)): \(err.description, privacy: .private)")
            pairingPhase = .failure("Pairing failed — try again.")
            Diag.error("Pairing failed", "Pairing")
        } catch {
            log.error(
                """
                Pairing failed for host=\(hostnameOrIP, privacy: .private(mask: .hash)): \
                \(error.localizedDescription, privacy: .private)
                """
            )
            pairingPhase = .failure("Pairing failed — try again.")
            Diag.error("Pairing failed", "Pairing")
        }
        pairingInFlight = false
    }

    /// Future: currently uncalled. Safari's self-signed-cert dead-end
    /// makes the host's web UI a worse pairing path than Glimmer's
    /// in-app flow, but the URL shape is centralised here so a future
    /// "show me what the host sees" affordance or embedded WKWebView
    /// helper has one canonical address to dial.
    func openSunshineWebUI(forHost host: String) {
        if let url = URL(string: "https://\(host):47990") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Menu-bar icon — three states the user can read at a glance:
    ///   * `moon.stars`                 — idle (default)
    ///   * `play.fill`                  — streaming
    ///   * `exclamationmark.triangle.fill` — error
    /// Reading `streamPhase` / `isStreaming` / `nativeStreamError`
    /// means `@Observable` automatically tracks the icon and SwiftUI
    /// rebuilds the MenuBarExtra label when any of them flip.
    /// SF Symbol for the menu-bar charm's STATE overrides (error/streaming);
    /// nil means idle, where the charm shows the custom Eclipse template mark
    /// (Assets.xcassets/MenuBarIcon — original art) instead of
    /// the old `moon.stars` stand-in. The alternate mark ships alongside as
    /// MenuBarIconAlt; swapping is a one-string change in GlimmerApp.
    var menuBarSystemImageName: String? {
        if nativeStreamError != nil { return "exclamationmark.triangle.fill" }
        if isStreaming { return "play.fill" }
        return nil
    }

    /// Battery of the first connected game controller that reports one, for
    /// the menu-bar "controller" charm. Read straight from the GameController
    /// registry — works whenever a pad is connected to the Mac (not only
    /// mid-stream), and is sampled fresh each time the menu is opened (a
    /// rebuild), so it doesn't need to be @Observable. Returns nil — hiding
    /// the charm — for wired-only pads / pads with no battery telemetry,
    /// INCLUDING macOS's .unknown + 0.0 no-data sentinel (Xbox over BT),
    /// which an unguarded read used to show as a false "0%". The hide is not
    /// a give-up: the next menu open re-reads, so the charm reappears the
    /// moment the OS reports data.
    var menuBarControllerBattery: (percent: Int, charging: Bool)? {
        // Prefer the HID-decoded battery: opening the DualSense over raw HID
        // makes gamecontrollerd drop the enhanced-report battery, so
        // GCController.battery reads nil while the reader is live. The HID
        // decode keeps the charm working in that case.
        if let hid = DualSenseHID.shared.battery {
            return (hid.percent, hid.charging)
        }
        for controller in GCController.controllers() {
            guard let battery = controller.battery,
                  let reading = ControllerBattery.uiReading(battery) else { continue }
            // An unknown STATE with a real level (DualSense: 0.95/.unknown)
            // still shows its percentage. Mapping nil-charging to false is
            // honest in THIS view because the charm's copy only ever ADDS
            // "· charging" — it never claims "on battery", so the unknown
            // case renders as the bare number.
            return (reading.percent, reading.charging == true)
        }
        return nil
    }
}
