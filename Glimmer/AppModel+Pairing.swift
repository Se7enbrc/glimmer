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
        WiFiRoamWatch.shared.start()
    }

    func afterStreamEnd() {
        WiFiRoamWatch.shared.stop()
        maybeOfferHIDPermission()
    }

    // MARK: Pairing

    /// One launchable app captured from the host's /applist right after pairing.
    /// A small named struct instead of a 4-field tuple; passed straight through
    /// to `saveHost`.
    struct PairedApp: Equatable {
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

    /// Opens a pairing session for the sheet. The launcher's poller stays
    /// paused until `cancelPairing`, so `pair` itself never touches polling.
    func beginPairing(address: String) -> PairingAttempt {
        let attempt = PairingAttempt(address: address)
        pairingAttempt = attempt
        pairingPhase = .idle
        hostStatusTask?.cancel()
        hostStatusTask = nil
        return attempt
    }

    /// Ends the sheet's session (Back, Cancel or close) and resumes polling,
    /// unless a newer attempt from another sheet has taken over.
    func cancelPairing(_ attempt: PairingAttempt) {
        if pairingAttempt == attempt { pairingAttempt = nil }
        guard pairingAttempt == nil else { return }
        pairingPhase = .idle
        restartHostStatusPolling()
    }

    private func checkPairing(_ attempt: PairingAttempt) throws {
        guard attempt.accepts(pairingAttempt, address: attempt.address, cancelled: Task.isCancelled) else {
            throw CancellationError()
        }
    }

    /// A hostname or IP literal the control transport can dial: no scheme,
    /// port, path or `%zone`. `normalizedPCAddress` cleans a paste into this.
    nonisolated static func isValidPCAddress(_ address: String) -> Bool {
        let pattern = #"^[A-Za-z0-9]([A-Za-z0-9._:-]*[A-Za-z0-9])?$"#
        return address.count <= 253 && address.range(of: pattern, options: .regularExpression) != nil
    }

    /// Cuts a typed or pasted entry down to its address, so Sunshine's own URL
    /// "https://192.168.1.10:47990/pin" becomes "192.168.1.10" and
    /// "[2001:db8::5]:47989" becomes "2001:db8::5". nil when that isn't dialable.
    nonisolated static func normalizedPCAddress(_ input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let scheme = text.range(of: "://") { text = String(text[scheme.upperBound...]) }
        text = String(text.prefix { !"/?#".contains($0) })
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            text = String(text[text.index(after: text.startIndex)..<close])
        } else if text.count(where: { $0 == ":" }) == 1 {
            text = String(text.prefix { $0 != ":" })
        }
        return isValidPCAddress(text) ? text : nil
    }

    func pair(attempt: PairingAttempt, pin: String) async -> Host? {
        guard (try? checkPairing(attempt)) != nil else { return nil }
        defer { if pairingAttempt == attempt { pairingAttempt = nil } }
        let address = attempt.address
        guard Self.isValidPCAddress(address) else {
            pairingPhase = .failure(.invalidAddress)
            return nil
        }
        guard pin.count == 4, pin.allSatisfy({ $0.isNumber }) else {
            pairingPhase = .failure(.rejected)
            return nil
        }
        pairingPhase = .connecting
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
            pairingPhase = .failure(.unreachable)
            return nil
        }
        guard !fetched.isRealGFE else {
            Diag.error("Pairing: PC runs NVIDIA GameStream, not Sunshine", "Pairing")
            pairingPhase = .failure(.gameStream)
            return nil
        }
        do {
            pairingPhase = .awaitingPin
            // Always the full handshake: this /serverinfo came over plain HTTP,
            // so nothing in it proves the PC already trusts this Mac.
            let paired = try await PairingClient(network: network, server: fetched).pair(pin: pin)
            try checkPairing(attempt)
            guard paired.uniqueId == fetched.uniqueId else { throw CancellationError() }
            let apps = await pairingApps(server: paired)
            try checkPairing(attempt)
            saveHost(
                uuid: paired.uniqueId,
                hostname: paired.serverName.isEmpty ? address : paired.serverName,
                address: address, serverCertPEM: paired.serverCertPEM,
                appVersion: paired.appVersion,
                apps: apps, macAddress: paired.macAddress)
            pairingPhase = .success
            Diag.notice("Pairing succeeded", "Pairing")
            return hosts.first { $0.id == paired.uniqueId }
        } catch {
            guard (try? checkPairing(attempt)) != nil else { return nil }
            // A timeout or a busy PC says so; every other cause (wrong PIN, signature,
            // status) is one `.rejected`, detail in the private log only (#10).
            log.error(
                """
                Pairing failed for host=\(address, privacy: .private(mask: .hash)): \
                \(String(describing: error), privacy: .private)
                """
            )
            let failure = error as? PairingFailure ?? .rejected
            Diag.error("Pairing failed: \(failure)", "Pairing")
            pairingPhase = .failure(failure)
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

    /// Sunshine's PIN page in this Mac's browser, for a headless PC. Sunshine
    /// serves it over HTTPS on 47990 with its own self-signed certificate.
    func openSunshinePINPage(forHost host: String) {
        let literal = host.contains(":") ? "[\(host)]" : host
        if let url = URL(string: "https://\(literal):47990/pin") {
            NSWorkspace.shared.open(url)
        }
    }
}
