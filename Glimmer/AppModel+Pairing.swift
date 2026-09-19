//
//  AppModel+Pairing.swift
//
//  Stream lifecycle, pairing, Sunshine web UI and menu-bar accessors.
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

extension AppModel {

    // MARK: Stream lifecycle hooks

    func beforeStreamStart() {
        if muteMacWhileStreaming { muteMac() }
        WiFiRoamWatch.shared.start()
    }

    func afterStreamEnd() {
        // Keyed off the did-mute latch inside restoreMac() (prePausedMacVolume
        // non-nil), NOT the live muteMacWhileStreaming flag: the toggle can be
        // flipped OFF mid-stream, and the old flag-gated restore then left the
        // Mac stuck at volume 0 - with the saved level destroyed by the next
        // muted stream's re-capture of that 0. Unconditional restore keeps
        // teardown symmetric with whatever beforeStreamStart() / the live
        // toggle (applyMutePreferenceMidStream) actually did, and is a no-op
        // when nothing was muted.
        restoreMac()
        WiFiRoamWatch.shared.stop()
        maybeOfferHIDPermission()
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
    /// SECURITY (#10) - note on PIN entropy:
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
    /// We deliberately keep 4 digits for protocol compatibility - GFE
    /// 3.x's pairing UI accepts any string but its pair-page may auto-
    /// submit on 4 chars (untested for 6); Sunshine accepts arbitrary
    /// length but a user typing six on a host UI that auto-submits at
    /// four is a footgun. If we ever validate 6-digit auto-submit
    /// behaviour on the current GFE + all Sunshine versions in the
    /// wild, this is the place to widen the range. The
    /// pin.count == 4 guard in `pair(attempt:pin:)` would also need
    /// to relax to >= 4.
    func generatePairingPIN() -> String {
        let pinValue = Int.random(in: 0...9999)
        return String(format: "%04d", pinValue)
    }

    func beginPairing(address: String) -> PairingAttempt {
        let attempt = PairingAttempt(address: address)
        pairingAttempt = attempt
        pairingPhase = .idle
        hostStatusTask?.cancel()
        hostStatusTask = nil
        return attempt
    }

    func cancelPairing(_ attempt: PairingAttempt) {
        guard pairingAttempt == attempt else { return }
        pairingAttempt = nil
        pairingPhase = .idle
        restartHostStatusPolling()
    }

    private func checkPairing(_ attempt: PairingAttempt) throws {
        guard attempt.accepts(pairingAttempt, address: attempt.address, cancelled: Task.isCancelled) else {
            throw CancellationError()
        }
    }

    func pair(attempt: PairingAttempt, pin: String) async -> Host? {
        guard (try? checkPairing(attempt)) != nil else { return nil }
        defer {
            if pairingAttempt == attempt {
                pairingAttempt = nil
                restartHostStatusPolling()
            }
        }
        let address = attempt.address
        let pattern = #"^[A-Za-z0-9]([A-Za-z0-9._:-]*[A-Za-z0-9])?$"#
        guard address.range(of: pattern, options: .regularExpression) != nil,
              address.count <= 253, !address.hasPrefix("-") else {
            pairingPhase = .failure("Hostname looks invalid. Use a name like tower.local or an IP.")
            return nil
        }
        guard pin.count == 4, pin.allSatisfy({ $0.isNumber }) else {
            pairingPhase = .failure("PIN must be 4 digits.")
            return nil
        }
        pairingPhase = .awaitingPin("Pairing… enter \(pin) on \(address).")
        let info = ServerInfo(address: address, uniqueId: address, serverName: address)
        let network = NetworkClient(server: info)
        let fetched: ServerInfo
        do {
            fetched = try await network.fetchServerInfo()
            try checkPairing(attempt)
        } catch {
            guard (try? checkPairing(attempt)) != nil else { return nil }
            let reason = error.localizedDescription
            log.error("Pairing: unreachable \(address, privacy: .private) - \(reason, privacy: .private)")
            Diag.error("Pairing: host unreachable", "Pairing")
            pairingPhase = .failure("Couldn't reach \(address). Make sure it's on and on this network.")
            return nil
        }
        do {
            pairingPhase = .verifying("Pairing… enter \(pin) on \(address).")
            let paired: ServerInfo
            if fetched.pairStatus == .paired {
                paired = fetched
            } else {
                paired = try await PairingClient(network: network, server: fetched).pair(pin: pin)
            }
            try checkPairing(attempt)
            guard paired.uniqueId == fetched.uniqueId else { throw CancellationError() }
            let apps = await pairingApps(server: paired)
            try checkPairing(attempt)
            saveHost(
                uuid: paired.uniqueId,
                hostname: paired.serverName.isEmpty ? address : paired.serverName,
                address: address, serverCertPEM: paired.serverCertPEM,
                appVersion: paired.appVersion, gfeVersion: paired.gfeVersion,
                apps: apps, macAddress: paired.macAddress)
            pairingPhase = .success("Paired with \(address) ✓")
            Diag.notice("Pairing succeeded", "Pairing")
            return hosts.first { $0.id == paired.uniqueId }
        } catch {
            guard (try? checkPairing(attempt)) != nil else { return nil }
            // One uniform message: the cause (wrong PIN, signature, status)
            // stays in the private log so nothing leaks over a shoulder (#10).
            log.error(
                """
                Pairing failed for host=\(address, privacy: .private(mask: .hash)): \
                \(error.localizedDescription, privacy: .private)
                """
            )
            Diag.error("Pairing failed", "Pairing")
            pairingPhase = .failure("Pairing failed - try again.")
            return nil
        }
    }

    private func pairingApps(server: ServerInfo) async -> [PairedApp] {
        let client = NetworkClient(server: server)
        if let apps = try? await client.appList(), !apps.isEmpty {
            return apps.map { PairedApp(id: $0.id, name: $0.name, hdr: $0.hdrCapable, hidden: $0.hidden) }
        }
        return [PairedApp(id: 881448767, name: "Desktop", hdr: false, hidden: false)]
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

    /// Menu-bar icon - three states the user can read at a glance:
    ///   * `moon.stars`                 - idle (default)
    ///   * `play.fill`                  - streaming
    ///   * `exclamationmark.triangle.fill` - error
    /// Reading `streamPhase` / `isStreaming` / `nativeStreamError`
    /// means `@Observable` automatically tracks the icon and SwiftUI
    /// rebuilds the MenuBarExtra label when any of them flip.
    /// SF Symbol for the menu-bar charm's STATE overrides (error/streaming);
    /// nil means idle, where the charm shows the custom Eclipse template mark
    /// (Assets.xcassets/MenuBarIcon - original art) instead of
    /// the old `moon.stars` stand-in. The alternate mark ships alongside as
    /// MenuBarIconAlt; swapping is a one-string change in GlimmerApp.
    var menuBarSystemImageName: String? {
        if nativeStreamError != nil { return "exclamationmark.triangle.fill" }
        if isStreaming { return "play.fill" }
        return nil
    }

    /// Battery of the first connected game controller that reports one, for
    /// the menu-bar "controller" charm. Read straight from the GameController
    /// registry - works whenever a pad is connected to the Mac (not only
    /// mid-stream), and is sampled fresh each time the menu is opened (a
    /// rebuild), so it doesn't need to be @Observable. Returns nil - hiding
    /// the charm - for wired-only pads / pads with no battery telemetry,
    /// INCLUDING macOS's .unknown + 0.0 no-data sentinel (Xbox over BT),
    /// which an unguarded read used to show as a false "0%". The hide is not
    /// a give-up: the next menu open re-reads, so the charm reappears the
    /// moment the OS reports data.
    var menuBarControllerBattery: (percent: Int, charging: Bool)? {
        // Prefer the HID-decoded battery: opening the DualSense over raw HID
        // makes gamecontrollerd drop the enhanced-report battery, so
        // GCController.battery reads nil while the reader is live. The HID
        // decode keeps the charm working in that case.
        for controller in GCController.controllers() {
            if let hid = DualSenseHID.shared.state(for: ObjectIdentifier(controller))?.battery {
                return (hid.percent, hid.charging)
            }
            guard let battery = controller.battery,
                  let reading = ControllerBattery.uiReading(battery) else { continue }
            // An unknown STATE with a real level (DualSense: 0.95/.unknown)
            // still shows its percentage. Mapping nil-charging to false is
            // honest in THIS view because the charm's copy only ever ADDS
            // "· charging" - it never claims "on battery", so the unknown
            // case renders as the bare number.
            return (reading.percent, reading.charging == true)
        }
        return nil
    }
}
